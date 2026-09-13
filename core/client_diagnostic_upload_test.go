package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/constant"
)

func TestClientDiagnosticUploadSessionAndErrors(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(oldHome) })
	if err := saveEncryptedFile(clientSessionPath(), []byte("test-session")); err != nil {
		t.Fatal(err)
	}
	status := 200
	response := `{"ret":1,"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/client/diagnostics" || request.Header.Get("Authorization") != "Bearer test-session" || request.Header.Get("User-Agent") != clientAPIUserAgent {
			t.Error("incorrect scoped diagnostic request")
		}
		writer.WriteHeader(status)
		_, _ = writer.Write([]byte(response))
	}))
	defer server.Close()
	call := func() string {
		return clientDiagnosticUpload(server.URL+"/client", json.RawMessage(`{"action":"status"}`))
	}
	if call() != response {
		t.Fatal("diagnostic response mismatch")
	}
	status, response = 401, "secret-server:8443 password=test"
	if call() != `{"ret":0,"error":"login-required"}` {
		t.Fatal("authentication failure not safely classified")
	}
	status = 500
	if strings.Contains(call(), "secret-server") {
		t.Fatal("upstream body leaked")
	}
	if clientDiagnosticUpload(server.URL, json.RawMessage(`{"action":"other"}`)) != `{"ret":0,"error":"invalid"}` {
		t.Fatal("unknown action accepted")
	}
}
