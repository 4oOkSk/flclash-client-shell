package main

import (
	"errors"
	"testing"
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
