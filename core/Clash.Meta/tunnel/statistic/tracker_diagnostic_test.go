package statistic

import (
	"context"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	metaAtomic "github.com/metacubex/mihomo/common/atomic"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
)

func TestClassifyTrackerEndReason(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "nil", err: nil, want: ""},
		{name: "eof", err: io.EOF, want: "eof"},
		{name: "deadline", err: context.DeadlineExceeded, want: "timeout"},
		{name: "reset", err: syscall.ECONNRESET, want: "reset"},
		{name: "refused", err: syscall.ECONNREFUSED, want: "refused"},
		{name: "unreachable", err: syscall.ENETUNREACH, want: "unreachable"},
		{name: "other", err: errors.New("opaque"), want: "io-error"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := classifyTrackerEndReason(test.err); got != test.want {
				t.Fatalf("classifyTrackerEndReason() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestFinalizeTrackerEndReason(t *testing.T) {
	tests := []struct {
		name     string
		reason   string
		upload   int64
		download int64
		want     string
	}{
		{name: "idle timeout overrides generic timeout", reason: "idle-timeout", upload: 5, download: 5, want: "idle-timeout"},
		{name: "network timeout wins", reason: "timeout", upload: 5, download: 5, want: "timeout"},
		{name: "no response", reason: "eof", upload: 5, want: "no-response"},
		{name: "idle", want: "idle"},
		{name: "eof", reason: "eof", download: 5, want: "eof"},
		{name: "closed", upload: 5, download: 5, want: "closed"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := finalizeTrackerEndReason(test.reason, test.upload, test.download); got != test.want {
				t.Fatalf("finalizeTrackerEndReason() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestUDPIdleTimeoutOverridesReadDeadlineError(t *testing.T) {
	lifecycle := trackerLifecycle{}
	lifecycle.recordEnd(context.DeadlineExceeded)
	lifecycle.recordIdleTimeout()
	lifecycle.finalize(time.Now().Add(-time.Minute), 100, 200)

	source := &TrackerInfo{
		UploadTotal:   metaAtomic.NewInt64(100),
		DownloadTotal: metaAtomic.NewInt64(200),
		Start:         time.Now().Add(-time.Minute),
		Lifecycle:     "active",
	}
	info := lifecycle.snapshot(source)
	if info.EndReason != "idle-timeout" {
		t.Fatalf("EndReason = %q, want idle-timeout", info.EndReason)
	}
	if info.Lifecycle != "closed" {
		t.Fatalf("Lifecycle = %q, want closed", info.Lifecycle)
	}
}

func TestUDPIdleTimeoutDoesNotMaskSpecificTransportFailure(t *testing.T) {
	lifecycle := trackerLifecycle{}
	lifecycle.recordEnd(syscall.ECONNREFUSED)
	lifecycle.recordIdleTimeout()
	lifecycle.finalize(time.Now().Add(-time.Minute), 100, 0)

	if lifecycle.reason != "refused" {
		t.Fatalf("end reason = %q, want refused", lifecycle.reason)
	}
}

func TestSpecificTransportFailureOverridesOpaqueIOError(t *testing.T) {
	lifecycle := trackerLifecycle{}
	lifecycle.recordEnd(errors.New("opaque"))
	lifecycle.recordEnd(syscall.ECONNREFUSED)
	lifecycle.finalize(time.Now().Add(-time.Second), 1, 0)

	if lifecycle.reason != "refused" {
		t.Fatalf("end reason = %q, want refused", lifecycle.reason)
	}
}

func TestTrackerInfoSnapshotDoesNotAliasMutableMetadata(t *testing.T) {
	source := &TrackerInfo{
		Metadata: &C.Metadata{
			Host:     "before.example.com",
			SrcGeoIP: []string{"CN"},
			DstGeoIP: []string{"US"},
		},
		UploadTotal:   metaAtomic.NewInt64(1),
		DownloadTotal: metaAtomic.NewInt64(2),
	}

	snapshot := trackerInfoSnapshot(source, "closed", 10, "closed")
	source.Metadata.Host = "after.example.com"
	source.Metadata.SrcGeoIP[0] = "ZZ"
	source.Metadata.DstGeoIP[0] = "ZZ"

	if snapshot.Metadata.Host != "before.example.com" {
		t.Fatalf("snapshot host = %q, want before.example.com", snapshot.Metadata.Host)
	}
	if snapshot.Metadata.SrcGeoIP[0] != "CN" || snapshot.Metadata.DstGeoIP[0] != "US" {
		t.Fatalf("snapshot geo metadata changed: src=%v dst=%v", snapshot.Metadata.SrcGeoIP, snapshot.Metadata.DstGeoIP)
	}
}

type diagnosticCloseConn struct {
	C.Conn
	closeCalls atomic.Int64
}

func TestCloseCallbackCanReenterTrackerClose(t *testing.T) {
	previousNotify := DefaultRequestCloseNotify
	defer func() { DefaultRequestCloseNotify = previousNotify }()

	manager := &Manager{}
	tracker := &tcpTracker{
		Conn: &diagnosticCloseConn{},
		TrackerInfo: &TrackerInfo{
			UUID:          utils.NewUUIDV4(),
			UploadTotal:   metaAtomic.NewInt64(1),
			DownloadTotal: metaAtomic.NewInt64(1),
			Start:         time.Now().Add(-time.Millisecond),
			Lifecycle:     "active",
		},
		manager:       manager,
		pushToManager: true,
	}
	manager.connections.Store(tracker.ID(), tracker)
	var callbacks atomic.Int64
	DefaultRequestCloseNotify = func(current Tracker) {
		callbacks.Add(1)
		_ = current.Close()
	}

	done := make(chan struct{})
	go func() {
		_ = tracker.Close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("reentrant close callback deadlocked")
	}
	if got := callbacks.Load(); got != 1 {
		t.Fatalf("close callbacks = %d, want 1", got)
	}
}

func (c *diagnosticCloseConn) Close() error {
	c.closeCalls.Add(1)
	return nil
}

func TestTrackerLifecycleHighChurnClosesExactlyOnce(t *testing.T) {
	const trackerCount = 1000

	previousNotify := DefaultRequestCloseNotify
	defer func() {
		DefaultRequestCloseNotify = previousNotify
	}()

	var notifications atomic.Int64
	var invalidSnapshots atomic.Int64
	DefaultRequestCloseNotify = func(tracker Tracker) {
		info := tracker.LifecycleInfo()
		if info.Lifecycle != "closed" || info.EndReason != "eof" || info.DurationMs < 0 {
			invalidSnapshots.Add(1)
		}
		notifications.Add(1)
	}

	manager := &Manager{}
	trackers := make([]*tcpTracker, 0, trackerCount)
	connections := make([]*diagnosticCloseConn, 0, trackerCount)
	for index := 0; index < trackerCount; index++ {
		connection := &diagnosticCloseConn{}
		tracker := &tcpTracker{
			Conn: connection,
			TrackerInfo: &TrackerInfo{
				UUID:          utils.NewUUIDV4(),
				UploadTotal:   metaAtomic.NewInt64(1),
				DownloadTotal: metaAtomic.NewInt64(1),
				Start:         time.Now().Add(-time.Millisecond),
				Lifecycle:     "active",
			},
			manager:       manager,
			pushToManager: true,
		}
		tracker.RecordEnd(io.EOF)
		manager.connections.Store(tracker.ID(), tracker)
		trackers = append(trackers, tracker)
		connections = append(connections, connection)
	}

	var waitGroup sync.WaitGroup
	waitGroup.Add(trackerCount * 2)
	for _, tracker := range trackers {
		for attempt := 0; attempt < 2; attempt++ {
			go func(current *tcpTracker) {
				defer waitGroup.Done()
				_ = current.Close()
			}(tracker)
		}
	}
	done := make(chan struct{})
	go func() {
		waitGroup.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("concurrent tracker closes did not complete")
	}

	if got := notifications.Load(); got != trackerCount {
		t.Fatalf("close notifications = %d, want %d", got, trackerCount)
	}
	if got := invalidSnapshots.Load(); got != 0 {
		t.Fatalf("invalid lifecycle snapshots = %d, want 0", got)
	}
	for index, connection := range connections {
		if got := connection.closeCalls.Load(); got != 1 {
			t.Fatalf("connection %d close calls = %d, want 1", index, got)
		}
	}
	remaining := 0
	manager.Range(func(Tracker) bool {
		remaining++
		return true
	})
	if remaining != 0 {
		t.Fatalf("manager retained %d closed trackers", remaining)
	}
}
