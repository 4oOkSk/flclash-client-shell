package dns

import (
	"context"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"github.com/metacubex/http"
)

func TestDoHCancelledQueryReleasesStalledTLSConnection(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	accepted := make(chan net.Conn, 1)
	closed := make(chan struct{})
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		accepted <- conn
		// Consume ClientHello without ever responding to the TLS handshake.
		io.Copy(io.Discard, conn)
		close(closed)
	}()

	doh := newDoHClient("https://"+listener.Addr().String()+"/dns-query", nil, false, nil, nil, "").(*dnsOverHTTPS)
	transport, err := doh.createTransport(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(transport.(*http.Transport).CloseIdleConnections)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, doh.url.String(), nil)
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		_, err := transport.RoundTrip(req)
		result <- err
	}()
	select {
	case conn := <-accepted:
		t.Cleanup(func() { conn.Close() })
	case <-time.After(5 * time.Second):
		t.Fatal("DoH did not connect to the stalled TLS server")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("query cancellation: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancelled query did not return")
	}
	select {
	case <-closed:
	case <-time.After(dialTimeout + 2*time.Second):
		t.Fatal("transport retained a stalled TLS connection after query cancellation")
	}
}
