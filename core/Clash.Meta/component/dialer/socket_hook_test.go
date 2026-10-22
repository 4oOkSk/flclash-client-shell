package dialer

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync"
	"syscall"
	"testing"
)

func preserveSocketHook(t *testing.T) {
	t.Helper()
	previous := GetDefaultSocketHook()
	t.Cleanup(func() { SetDefaultSocketHook(previous) })
}

func TestSocketHookSnapshotSurvivesRemovalAndReplacement(t *testing.T) {
	for _, kind := range []string{"dial", "listen", "icmp"} {
		t.Run(kind, func(t *testing.T) {
			preserveSocketHook(t)
			stopped := errors.New("protect callback belongs to a stopped VPN")
			calls := 0
			SetDefaultSocketHook(func(network, address string, c syscall.RawConn) error {
				calls++
				if network != "udp4" || address != "127.0.0.1:53" {
					t.Fatalf("unexpected socket: %s %s", network, address)
				}
				return stopped
			})
			var control SocketControl
			switch kind {
			case "dial":
				d := &net.Dialer{}
				socketHookToToDialer(d, GetDefaultSocketHook())
				control = func(network, address string, c syscall.RawConn) error {
					return d.ControlContext(context.Background(), network, address, c)
				}
			case "listen":
				lc := &net.ListenConfig{}
				socketHookToListenConfig(lc, GetDefaultSocketHook())
				control = lc.Control
			case "icmp":
				control = ICMPControl(netip.MustParseAddr("127.0.0.1"))
			}
			// Reproduce stop between control installation and socket creation.
			SetDefaultSocketHook(nil)
			if err := control("udp4", "127.0.0.1:53", nil); !errors.Is(err, stopped) {
				t.Fatalf("removed hook must fail closed, got %v", err)
			}
			SetDefaultSocketHook(func(string, string, syscall.RawConn) error {
				t.Fatal("a socket must not switch to another VPN's protect callback")
				return nil
			})
			if err := control("udp4", "127.0.0.1:53", nil); !errors.Is(err, stopped) {
				t.Fatalf("replaced hook must retain the original protection, got %v", err)
			}
			if calls != 2 {
				t.Fatalf("original callback called %d times, want 2", calls)
			}
		})
	}
}

func TestSocketHookSnapshotRunsOutsideUpdateLock(t *testing.T) {
	preserveSocketHook(t)
	SetDefaultSocketHook(func(string, string, syscall.RawConn) error {
		SetDefaultSocketHook(nil)
		return nil
	})
	d := &net.Dialer{}
	socketHookToToDialer(d, GetDefaultSocketHook())
	if err := d.ControlContext(context.Background(), "tcp4", "127.0.0.1:80", nil); err != nil {
		t.Fatal(err)
	}
	if GetDefaultSocketHook() != nil {
		t.Fatal("callback could not remove the hook")
	}
}

func TestSocketHookConcurrentUpdatesAndSnapshots(t *testing.T) {
	preserveSocketHook(t)
	stopped := errors.New("stopped VPN")
	hook := SocketControl(func(string, string, syscall.RawConn) error { return stopped })
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			SetDefaultSocketHook(hook)
			SetDefaultSocketHook(nil)
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			if snapshot := GetDefaultSocketHook(); snapshot != nil {
				d := &net.Dialer{}
				socketHookToToDialer(d, snapshot)
				if err := d.ControlContext(context.Background(), "udp4", "127.0.0.1:53", nil); !errors.Is(err, stopped) {
					t.Errorf("lost socket protection: %v", err)
				}
			}
		}
	}()
	wg.Wait()
}
