package dialer

import (
	"context"
	"net"
	"sync"
	"syscall"
)

// SocketControl
// never change type traits because it's used in CMFA
type SocketControl func(network, address string, conn syscall.RawConn) error

// DefaultSocketHook
// never change type traits because it's used in CMFA
// Use SetDefaultSocketHook for concurrent updates.
var DefaultSocketHook SocketControl

var defaultSocketHookMu sync.RWMutex

// SetDefaultSocketHook synchronizes hook updates with new socket creation.
func SetDefaultSocketHook(hook SocketControl) {
	defaultSocketHookMu.Lock()
	DefaultSocketHook = hook
	defaultSocketHookMu.Unlock()
}

// GetDefaultSocketHook returns a snapshot that remains valid after an update.
func GetDefaultSocketHook() SocketControl {
	defaultSocketHookMu.RLock()
	hook := DefaultSocketHook
	defaultSocketHookMu.RUnlock()
	return hook
}

func socketHookToToDialer(dialer *net.Dialer, hook SocketControl) {
	// A queued socket must retain its protection, even after the global hook is cleared.
	addControlToDialer(dialer, func(ctx context.Context, network, address string, c syscall.RawConn) error {
		return hook(network, address, c)
	})
}

func socketHookToListenConfig(lc *net.ListenConfig, hook SocketControl) {
	addControlToListenConfig(lc, func(ctx context.Context, network, address string, c syscall.RawConn) error {
		return hook(network, address, c)
	})
}
