package statistic

import (
	"io"
	"net"
	"time"

	"github.com/metacubex/mihomo/common/atomic"
	"github.com/metacubex/mihomo/common/buf"
	N "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"

	"github.com/gofrs/uuid/v5"
)

type Tracker interface {
	ID() string
	Close() error
	Info() *TrackerInfo
	LifecycleInfo() *TrackerInfo
	ReportLifecycle() bool
	C.Connection
}

type TrackerInfo struct {
	UUID             uuid.UUID    `json:"id"`
	Metadata         *C.Metadata  `json:"metadata"`
	UploadTotal      atomic.Int64 `json:"upload"`
	DownloadTotal    atomic.Int64 `json:"download"`
	Start            time.Time    `json:"start"`
	Chain            C.Chain      `json:"chains"`
	ProviderChain    C.Chain      `json:"providerChains"`
	Rule             string       `json:"rule"`
	RulePayload      string       `json:"rulePayload"`
	Lifecycle        string       `json:"lifecycle,omitempty"`
	DurationMs       int64        `json:"durationMs,omitempty"`
	EndReason        string       `json:"endReason,omitempty"`
	DiagnosticRoute  string       `json:"diagnosticRoute,omitempty"`
	DiagnosticRule   string       `json:"diagnosticRule,omitempty"`
	DiagnosticPolicy string       `json:"diagnosticPolicy,omitempty"`
}

type tcpTracker struct {
	C.Conn `json:"-"`
	*TrackerInfo
	manager *Manager

	pushToManager bool `json:"-"`
	lifecycle     trackerLifecycle
}

func (tt *tcpTracker) ID() string {
	return tt.UUID.String()
}

func (tt *tcpTracker) Info() *TrackerInfo {
	return tt.TrackerInfo
}

func (tt *tcpTracker) LifecycleInfo() *TrackerInfo {
	return tt.lifecycle.snapshot(tt.TrackerInfo)
}

func (tt *tcpTracker) ReportLifecycle() bool {
	return tt.pushToManager
}

func (tt *tcpTracker) RecordEnd(err error) {
	tt.lifecycle.recordEnd(err)
}

func (tt *tcpTracker) Read(b []byte) (int, error) {
	n, err := tt.Conn.Read(b)
	tt.RecordEnd(err)
	download := int64(n)
	if tt.pushToManager {
		tt.manager.PushDownloaded(tt.Conn.Chains().Last(), download)
	}
	tt.DownloadTotal.Add(download)
	return n, err
}

func (tt *tcpTracker) ReadBuffer(buffer *buf.Buffer) (err error) {
	err = tt.Conn.ReadBuffer(buffer)
	tt.RecordEnd(err)
	download := int64(buffer.Len())
	if tt.pushToManager {
		tt.manager.PushDownloaded(tt.Chains().Last(), download)
	}
	tt.DownloadTotal.Add(download)
	return
}

func (tt *tcpTracker) UnwrapReader() (io.Reader, []N.CountFunc) {
	return tt.Conn, []N.CountFunc{func(download int64) {
		if tt.pushToManager {
			tt.manager.PushDownloaded(tt.Chains().Last(), download)
		}
		tt.DownloadTotal.Add(download)
	}}
}

func (tt *tcpTracker) Write(b []byte) (int, error) {
	n, err := tt.Conn.Write(b)
	tt.RecordEnd(err)
	upload := int64(n)
	if tt.pushToManager {
		tt.manager.PushUploaded(tt.Chains().Last(), upload)
	}
	tt.UploadTotal.Add(upload)
	return n, err
}

func (tt *tcpTracker) WriteBuffer(buffer *buf.Buffer) (err error) {
	upload := int64(buffer.Len())
	err = tt.Conn.WriteBuffer(buffer)
	tt.RecordEnd(err)
	if tt.pushToManager {
		tt.manager.PushUploaded(tt.Chains().Last(), upload)
	}
	tt.UploadTotal.Add(upload)
	return
}

func (tt *tcpTracker) UnwrapWriter() (io.Writer, []N.CountFunc) {
	return tt.Conn, []N.CountFunc{func(upload int64) {
		if tt.pushToManager {
			tt.manager.PushUploaded(tt.Chains().Last(), upload)
		}
		tt.UploadTotal.Add(upload)
	}}
}

func (tt *tcpTracker) Close() error {
	closedNow := false
	tt.lifecycle.closeOnce.Do(func() {
		tt.lifecycle.closeErr = tt.Conn.Close()
		tt.RecordEnd(tt.lifecycle.closeErr)
		tt.lifecycle.finalize(
			tt.Start,
			tt.UploadTotal.Load(),
			tt.DownloadTotal.Load(),
		)
		tt.manager.Leave(tt)
		closedNow = true
	})
	if closedNow {
		notifyRequestClose(tt)
	}
	return tt.lifecycle.closeErr
}

func (tt *tcpTracker) Upstream() any {
	return tt.Conn
}

func NewTCPTracker(conn C.Conn, manager *Manager, metadata *C.Metadata, rule C.Rule, uploadTotal int64, downloadTotal int64, pushToManager bool) *tcpTracker {
	metadata.RemoteDst = conn.RemoteDestination()

	tt := &tcpTracker{
		Conn:    conn,
		manager: manager,
		TrackerInfo: &TrackerInfo{
			UUID:          utils.NewUUIDV4(),
			Start:         time.Now(),
			Metadata:      metadata,
			Chain:         conn.Chains(),
			ProviderChain: conn.ProviderChains(),
			Rule:          "",
			UploadTotal:   atomic.NewInt64(uploadTotal),
			DownloadTotal: atomic.NewInt64(downloadTotal),
			Lifecycle:     "active",
		},
		pushToManager: pushToManager,
	}

	if pushToManager {
		if uploadTotal > 0 {
			manager.PushUploaded(tt.Chains().Last(), uploadTotal)
		}
		if downloadTotal > 0 {
			manager.PushDownloaded(tt.Chains().Last(), downloadTotal)
		}
	}

	if rule != nil {
		tt.TrackerInfo.Rule = rule.RuleType().String()
		tt.TrackerInfo.RulePayload = rule.Payload()
	}

	manager.Join(tt)
	return tt
}

type udpTracker struct {
	C.PacketConn `json:"-"`
	*TrackerInfo
	manager *Manager

	pushToManager bool `json:"-"`
	lifecycle     trackerLifecycle
}

func (ut *udpTracker) ID() string {
	return ut.UUID.String()
}

func (ut *udpTracker) Info() *TrackerInfo {
	return ut.TrackerInfo
}

func (ut *udpTracker) LifecycleInfo() *TrackerInfo {
	return ut.lifecycle.snapshot(ut.TrackerInfo)
}

func (ut *udpTracker) ReportLifecycle() bool {
	return ut.pushToManager
}

func (ut *udpTracker) RecordEnd(err error) {
	ut.lifecycle.recordEnd(err)
}

func (ut *udpTracker) RecordIdleTimeout() {
	ut.lifecycle.recordIdleTimeout()
}

func (ut *udpTracker) ReadFrom(b []byte) (int, net.Addr, error) {
	n, addr, err := ut.PacketConn.ReadFrom(b)
	ut.RecordEnd(err)
	download := int64(n)
	if ut.pushToManager {
		ut.manager.PushDownloaded(ut.Chains().Last(), download)
	}
	ut.DownloadTotal.Add(download)
	return n, addr, err
}

func (ut *udpTracker) WaitReadFrom() (data []byte, put func(), addr net.Addr, err error) {
	data, put, addr, err = ut.PacketConn.WaitReadFrom()
	ut.RecordEnd(err)
	download := int64(len(data))
	if ut.pushToManager {
		ut.manager.PushDownloaded(ut.Chains().Last(), download)
	}
	ut.DownloadTotal.Add(download)
	return
}

func (ut *udpTracker) WriteTo(b []byte, addr net.Addr) (int, error) {
	n, err := ut.PacketConn.WriteTo(b, addr)
	ut.RecordEnd(err)
	upload := int64(n)
	if ut.pushToManager {
		ut.manager.PushUploaded(ut.Chains().Last(), upload)
	}
	ut.UploadTotal.Add(upload)
	return n, err
}

func (ut *udpTracker) Close() error {
	closedNow := false
	ut.lifecycle.closeOnce.Do(func() {
		ut.lifecycle.closeErr = ut.PacketConn.Close()
		ut.RecordEnd(ut.lifecycle.closeErr)
		ut.lifecycle.finalize(
			ut.Start,
			ut.UploadTotal.Load(),
			ut.DownloadTotal.Load(),
		)
		ut.manager.Leave(ut)
		closedNow = true
	})
	if closedNow {
		notifyRequestClose(ut)
	}
	return ut.lifecycle.closeErr
}

func (ut *udpTracker) Upstream() any {
	return ut.PacketConn
}

func NewUDPTracker(conn C.PacketConn, manager *Manager, metadata *C.Metadata, rule C.Rule, uploadTotal int64, downloadTotal int64, pushToManager bool) *udpTracker {
	metadata.RemoteDst = conn.RemoteDestination()

	ut := &udpTracker{
		PacketConn: conn,
		manager:    manager,
		TrackerInfo: &TrackerInfo{
			UUID:          utils.NewUUIDV4(),
			Start:         time.Now(),
			Metadata:      metadata,
			Chain:         conn.Chains(),
			ProviderChain: conn.ProviderChains(),
			Rule:          "",
			UploadTotal:   atomic.NewInt64(uploadTotal),
			DownloadTotal: atomic.NewInt64(downloadTotal),
			Lifecycle:     "active",
		},
		pushToManager: pushToManager,
	}

	if pushToManager {
		if uploadTotal > 0 {
			manager.PushUploaded(ut.Chains().Last(), uploadTotal)
		}
		if downloadTotal > 0 {
			manager.PushDownloaded(ut.Chains().Last(), downloadTotal)
		}
	}

	if rule != nil {
		ut.TrackerInfo.Rule = rule.RuleType().String()
		ut.TrackerInfo.RulePayload = rule.Payload()
	}

	manager.Join(ut)
	return ut
}
