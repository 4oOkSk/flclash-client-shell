package main

import (
	"io"
	"net/http"
	"testing"
)

func TestNewClientAPIRequest(t *testing.T) {
	req, err := newClientAPIRequest(http.MethodPost, "https://example.test/client/login", []byte("{}"))
	if err != nil {
		t.Fatal(err)
	}
	if req.Header.Get("User-Agent") != clientAPIUserAgent {
		t.Fatalf("unexpected user agent: %q", req.Header.Get("User-Agent"))
	}
	if req.Header.Get("Content-Type") != "application/json" {
		t.Fatalf("unexpected content type: %q", req.Header.Get("Content-Type"))
	}
	body, err := io.ReadAll(req.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "{}" {
		t.Fatalf("unexpected body: %q", body)
	}
}
