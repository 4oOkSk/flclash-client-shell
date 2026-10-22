//go:build linux && with_gvisor

package main

import (
	"context"
	"net/netip"
	"runtime"
	"strings"
	"testing"
	"time"

	tun "github.com/metacubex/sing-tun"
	"golang.org/x/sys/unix"
)

func pendingTunReads() int {
	buffer := make([]byte, 1<<20)
	length := runtime.Stack(buffer, true)
	return strings.Count(string(buffer[:length]), "rawfile.BlockingReadvUntilStopped(")
}

func TestGVisorCloseStopsPendingRead(test *testing.T) {
	if pendingTunReads() != 0 {
		test.Fatal("test requires no pre-existing TUN reader")
	}
	descriptors, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM|unix.SOCK_NONBLOCK, 0)
	if err != nil {
		test.Fatal(err)
	}
	defer unix.Close(descriptors[1])
	options := tun.Options{
		FileDescriptor: descriptors[0],
		MTU:            1500,
		Inet4Address:   []netip.Prefix{netip.MustParsePrefix("172.19.0.1/30")},
	}
	device, err := tun.New(options)
	if err != nil {
		unix.Close(descriptors[0])
		test.Fatal(err)
	}
	deviceClosed := false
	defer func() {
		if !deviceClosed {
			device.Close()
		}
	}()
	tunStack, err := tun.NewGVisor(tun.StackOptions{
		Context: context.Background(), Tun: device, TunOptions: options,
	})
	if err != nil {
		test.Fatal(err)
	}
	stackClosed := false
	defer func() {
		unix.Write(descriptors[1], []byte{0})
		if !stackClosed {
			tunStack.Close()
		}
	}()
	if err := tunStack.Start(); err != nil {
		test.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for pendingTunReads() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if pendingTunReads() != 1 {
		test.Fatal("expected one waiting TUN reader")
	}
	started := time.Now()
	err = tunStack.Close()
	stackClosed = true
	if err != nil {
		test.Fatal(err)
	}
	err = device.Close()
	deviceClosed = true
	if err != nil {
		test.Fatal(err)
	}
	deadline = time.Now().Add(100 * time.Millisecond)
	for pendingTunReads() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if pendingTunReads() != 0 {
		test.Fatal("Close returned but a TUN reader still holds the closed descriptor in poll")
	}
	test.Logf("reader stopped and descriptor closed in %s", time.Since(started))
}
