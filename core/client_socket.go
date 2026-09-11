package main

import (
	"errors"
	"sync/atomic"
	"syscall"

	"github.com/metacubex/mihomo/log"
)

var clientProtectFailures atomic.Uint64
var errClientSocketProtection = errors.New("VPN socket protection failed")

func protectClientSocket(conn syscall.RawConn, protectSocket func(int) bool) error {
	protected := false
	err := conn.Control(func(fd uintptr) {
		protected = protectSocket(int(fd))
	})
	if err != nil {
		return err
	}
	if !protected {
		if clientProtectFailures.Add(1) == 1 {
			log.Warnln("[TUN] VPN socket protection failed; connection blocked")
		}
		return errClientSocketProtection
	}
	return nil
}
