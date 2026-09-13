package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/constant"
	"golang.org/x/crypto/nacl/box"
)

func TestClientDiagnosticUploadSeparatesSessionFromDropCredential(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome, oldHTTP := constant.Path.HomeDir(), diagnosticHTTP
	constant.SetHomeDir(t.TempDir())
	diagnosticGrant, diagnosticGrantSession = clientDiagnosticGrant{}, ""
	t.Cleanup(func() {
		constant.SetHomeDir(oldHome)
		diagnosticHTTP = oldHTTP
		diagnosticGrant = clientDiagnosticGrant{}
		diagnosticGrantSession = ""
	})
	if err := saveEncryptedFile(clientSessionPath(), []byte("test-session")); err != nil {
		t.Fatal(err)
	}
	status, configCalls, uploadCalls := 200, 0, 0
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/client/config" {
			configCalls++
			if request.Header.Get("Cookie") != "client_session=test-session" {
				t.Error("missing authenticated grant request")
			}
			var body struct {
				EPK            string `json:"epk"`
				DiagnosticOnly bool   `json:"diagnostic_only"`
			}
			if json.NewDecoder(request.Body).Decode(&body) != nil || !body.DiagnosticOnly {
				t.Error("grant request rendered normal configuration")
			}
			publicBytes, _ := base64.StdEncoding.DecodeString(body.EPK)
			var public [32]byte
			copy(public[:], publicBytes)
			payload, _ := json.Marshal(map[string]interface{}{"diagnostics": clientDiagnosticGrant{Endpoint: server.URL + "/harborproxy-logdrop", Token: strings.Repeat("a", 64), Expires: time.Now().Unix() + 3600}})
			cipher, _ := box.SealAnonymous(nil, payload, &public, rand.Reader)
			_ = json.NewEncoder(writer).Encode(map[string]interface{}{"ret": 1, "cipher": base64.StdEncoding.EncodeToString(cipher)})
			return
		}
		uploadCalls++
		if request.URL.Path != "/harborproxy-logdrop" || request.Header.Get("Cookie") != "" || request.Header.Get("Authorization") != "Bearer "+strings.Repeat("a", 64) {
			t.Error("panel session crossed into log storage")
		}
		writer.WriteHeader(status)
		if status == 200 {
			_, _ = writer.Write([]byte(`{"ret":1,"state":"ready","path":"/files/harborproxylogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jsonl"}`))
		} else {
			_, _ = writer.Write([]byte("node.example:8443 password=secret"))
		}
	}))
	defer server.Close()
	diagnosticHTTP = func() *http.Client { return server.Client() }
	call := func() string {
		return clientDiagnosticUpload(server.URL+"/client", json.RawMessage(`{"action":"status","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`))
	}
	if !strings.Contains(call(), server.URL+"/files/harborproxylogs/") {
		t.Fatal("private report URL missing")
	}
	status = 500
	if strings.Contains(call(), "node.example") {
		t.Fatal("raw error leaked")
	}
	status = 429
	if !strings.Contains(call(), "rate-limited") {
		t.Fatal("missing quota classification")
	}
	if configCalls != 1 || uploadCalls != 3 {
		t.Fatal("grant caching failed")
	}
	if !strings.Contains(clientDiagnosticUpload(server.URL, json.RawMessage(`{"action":"other"}`)), "invalid") {
		t.Fatal("unknown action accepted")
	}
}
