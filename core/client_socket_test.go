package main

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/netip"
	"syscall"
	"testing"

	"github.com/metacubex/mihomo/component/dialer"
	"golang.org/x/sync/semaphore"
)

type clientTestRawConn struct {
	err error
}

func (conn clientTestRawConn) Control(callback func(uintptr)) error {
	if conn.err == nil {
		callback(42)
	}
	return conn.err
}

func (conn clientTestRawConn) Read(func(uintptr) bool) error  { return nil }
func (conn clientTestRawConn) Write(func(uintptr) bool) error { return nil }

func TestClientSocketProtectionFailsClosed(t *testing.T) {
	before := clientProtectFailures.Load()
	if err := protectClientSocket(clientTestRawConn{}, func(fd int) bool { return fd == 42 }); err != nil {
		t.Fatal(err)
	}
	if err := protectClientSocket(clientTestRawConn{}, func(int) bool { return false }); !errors.Is(err, errClientSocketProtection) {
		t.Fatalf("unprotected socket accepted: %v", err)
	}
	controlErr := errors.New("control failed")
	if err := protectClientSocket(clientTestRawConn{err: controlErr}, func(int) bool {
		t.Fatal("callback after control failure")
		return true
	}); !errors.Is(err, controlErr) {
		t.Fatalf("control error lost: %v", err)
	}
	if clientProtectFailures.Load() != before+1 {
		t.Fatal("protection failure counter mismatch")
	}
}

func TestClientSocketSnapshotFailsClosedAfterTunTeardown(t *testing.T) {
	previous := dialer.GetDefaultSocketHook()
	t.Cleanup(func() { dialer.SetDefaultSocketHook(previous) })
	limit := semaphore.NewWeighted(tunCallbackConcurrency)
	active := true
	dialer.SetDefaultSocketHook(func(_, _ string, conn syscall.RawConn) error {
		return protectClientSocket(conn, func(fd int) bool {
			if err := limit.Acquire(context.Background(), 1); err != nil {
				return false
			}
			defer limit.Release(1)
			return active && fd == 42
		})
	})
	control := dialer.ICMPControl(netip.MustParseAddr("127.0.0.1"))
	if err := control("udp4", "127.0.0.1:53", clientTestRawConn{}); err != nil {
		t.Fatal(err)
	}
	if err := closeTunAfterCallbacks(limit, func() io.Closer {
		active = false
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	dialer.SetDefaultSocketHook(nil)
	if err := control("udp4", "127.0.0.1:53", clientTestRawConn{}); !errors.Is(err, errClientSocketProtection) {
		t.Fatalf("late socket was not rejected by the stopped VPN: %v", err)
	}
	dialer.SetDefaultSocketHook(func(string, string, syscall.RawConn) error {
		t.Fatal("old socket used a new VPN callback")
		return nil
	})
	if err := control("udp4", "127.0.0.1:53", clientTestRawConn{}); !errors.Is(err, errClientSocketProtection) {
		t.Fatalf("old socket bypassed its original VPN protection: %v", err)
	}
}

func TestTunSocketHookWritesUseSynchronizedSetter(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "lib.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	setters := 0
	ast.Inspect(file, func(node ast.Node) bool {
		if assignment, ok := node.(*ast.AssignStmt); ok {
			for _, lhs := range assignment.Lhs {
				if selector, ok := lhs.(*ast.SelectorExpr); ok {
					if pkg, ok := selector.X.(*ast.Ident); ok && pkg.Name == "dialer" && selector.Sel.Name == "DefaultSocketHook" {
						t.Error("TUN hook writes must not race socket creation")
					}
				}
			}
		}
		if call, ok := node.(*ast.CallExpr); ok {
			if selector, ok := call.Fun.(*ast.SelectorExpr); ok {
				if pkg, ok := selector.X.(*ast.Ident); ok && pkg.Name == "dialer" && selector.Sel.Name == "SetDefaultSocketHook" {
					setters++
				}
			}
		}
		return true
	})
	if setters != 2 {
		t.Fatalf("TUN init/remove must use the setter, got %d calls", setters)
	}
}
