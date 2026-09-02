package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/constant"
	"golang.org/x/crypto/nacl/box"
)

func TestClientAPIUsesDedicatedUserAgent(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(oldHome) })

	const session = "test-session"
	const config = "mixed-port: 7890\n"
	loginCalls := 0
	configCalls := 0
	logoutCalls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("User-Agent"); got != clientAPIUserAgent {
			t.Errorf("unexpected user agent: %q", got)
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Errorf("unexpected content type: %q", got)
		}
		switch r.URL.Path {
		case clientLoginEndpointPath:
			loginCalls++
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ret": 1, "msg": "ok", "session": session,
			})
		case clientConfigEndpointPath:
			configCalls++
			if got := r.Header.Get("Cookie"); got != "client_session="+session {
				t.Errorf("unexpected cookie: %q", got)
			}
			var payload map[string]string
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Errorf("decode config request: %v", err)
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			epk, err := base64.StdEncoding.DecodeString(payload["epk"])
			if err != nil || len(epk) != 32 {
				t.Errorf("bad epk: len=%d err=%v", len(epk), err)
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			var epkArray [32]byte
			copy(epkArray[:], epk)
			plaintext, err := json.Marshal(clientConfigPayload{
				Config: config,
				Account: clientAccountInfo{
					RemainingBytes: 1024,
					ExpireAt:       1_800_000_000,
				},
			})
			if err != nil {
				t.Errorf("encode config: %v", err)
				return
			}
			cipher, err := box.SealAnonymous(nil, plaintext, &epkArray, rand.Reader)
			if err != nil {
				t.Errorf("seal config: %v", err)
				http.Error(w, "server error", http.StatusInternalServerError)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ret": 1, "etag": "etag", "cipher": base64.StdEncoding.EncodeToString(cipher),
			})
		case clientLogoutEndpointPath:
			logoutCalls++
			if got := r.Header.Get("Cookie"); got != "client_session="+session {
				t.Errorf("unexpected logout cookie: %q", got)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"ret": 1, "msg": "ok"})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	if err := clientLogin(srv.URL, "user@example.test", "password", ""); err != nil {
		t.Fatal(err)
	}
	got, err := fetchConfigFromClient(srv.URL, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got != config {
		t.Fatalf("unexpected config: %q", got)
	}
	if err := clientClear(srv.URL); err != nil {
		t.Fatal(err)
	}
	if clientHasSession() {
		t.Fatal("client session still exists after logout")
	}
	if loginCalls != 1 || configCalls != 1 || logoutCalls != 1 {
		t.Fatalf("unexpected calls: login=%d config=%d logout=%d", loginCalls, configCalls, logoutCalls)
	}
}

func TestClientClearWorksOffline(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(oldHome) })

	if err := saveEncryptedFile(clientSessionPath(), []byte("offline-session")); err != nil {
		t.Fatal(err)
	}
	if err := clientClear("http://127.0.0.1:1"); err != nil {
		t.Fatal(err)
	}
	if clientHasSession() {
		t.Fatal("client session still exists after offline clear")
	}
}

func TestClientAuthenticationFailureClearsLocalAuthenticationState(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(oldHome) })

	const session = "revoked-session"
	const config = "mixed-port: 7890\n"
	if err := saveEncryptedFile(clientSessionPath(), []byte(session)); err != nil {
		t.Fatal(err)
	}
	envelope, err := json.Marshal(clientConfigCacheEnvelope{
		SessionID: clientSessionID(session),
		Etag:      "revoked-etag",
		Config:    config,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := saveEncryptedFile(clientConfigPath(), envelope); err != nil {
		t.Fatal(err)
	}
	if err := saveConfigCache(config); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(map[string]any{"ret": 0, "msg": "authentication required"})
	}))
	defer srv.Close()

	_, err = fetchConfigFromClient(srv.URL, 0)
	var hardError clientHardError
	if !errors.As(err, &hardError) {
		t.Fatalf("expected authentication error, got %v", err)
	}
	if clientHasSession() {
		t.Fatal("revoked client session still exists")
	}
	for _, path := range []string{clientSessionPath(), clientConfigPath(), cachePath()} {
		if _, statErr := os.Stat(path); !errors.Is(statErr, os.ErrNotExist) {
			t.Fatalf("revoked client state still exists at %s: %v", path, statErr)
		}
	}
}

func TestClientAuthenticationStatusClearsStateWithoutJSON(t *testing.T) {
	tests := []struct {
		name   string
		status int
		body   string
	}{
		{name: "unauthorized empty", status: http.StatusUnauthorized},
		{name: "unauthorized html", status: http.StatusUnauthorized, body: "<html>unauthorized</html>"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			setupEnrollTestSecrets(t)
			oldHome := constant.Path.HomeDir()
			constant.SetHomeDir(t.TempDir())
			t.Cleanup(func() { constant.SetHomeDir(oldHome) })

			const session = "rejected-session"
			const config = "mixed-port: 7890\n"
			if err := saveEncryptedFile(clientSessionPath(), []byte(session)); err != nil {
				t.Fatal(err)
			}
			envelope, err := json.Marshal(clientConfigCacheEnvelope{
				SessionID: clientSessionID(session),
				Etag:      "rejected-etag",
				Config:    config,
			})
			if err != nil {
				t.Fatal(err)
			}
			if err := saveEncryptedFile(clientConfigPath(), envelope); err != nil {
				t.Fatal(err)
			}
			if err := saveConfigCache(config); err != nil {
				t.Fatal(err)
			}

			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer srv.Close()

			_, err = fetchConfigFromClient(srv.URL, 0)
			var hardError clientHardError
			if !errors.As(err, &hardError) {
				t.Fatalf("expected authentication error, got %v", err)
			}
			if clientHasSession() {
				t.Fatal("rejected client session still exists")
			}
			for _, path := range []string{clientSessionPath(), clientConfigPath(), cachePath()} {
				if _, statErr := os.Stat(path); !errors.Is(statErr, os.ErrNotExist) {
					t.Fatalf("rejected client state still exists at %s: %v", path, statErr)
				}
			}
		})
	}
}

func TestClientConfigForbiddenPreservesStateAndReturnsReason(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome := constant.Path.HomeDir()
	t.Cleanup(func() { constant.SetHomeDir(oldHome) })

	tests := []struct {
		name    string
		body    string
		message string
	}{
		{name: "json reason", body: `{"ret":0,"msg":"account expired"}`, message: "account expired"},
		{name: "empty", message: "403 Forbidden"},
		{name: "html", body: "<html>forbidden</html>", message: "403 Forbidden"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			constant.SetHomeDir(t.TempDir())
			const session = "restricted-session"
			const config = "mixed-port: 7890\n"
			if err := saveEncryptedFile(clientSessionPath(), []byte(session)); err != nil {
				t.Fatal(err)
			}
			envelope, err := json.Marshal(clientConfigCacheEnvelope{
				SessionID: clientSessionID(session),
				Etag:      "restricted-etag",
				Config:    config,
			})
			if err != nil {
				t.Fatal(err)
			}
			if err := saveEncryptedFile(clientConfigPath(), envelope); err != nil {
				t.Fatal(err)
			}
			if err := saveConfigCache(config); err != nil {
				t.Fatal(err)
			}

			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(test.body))
			}))
			defer srv.Close()

			got, err := fetchConfigFromClient(srv.URL, 0)
			if got != "" {
				t.Fatalf("forbidden config request fell back to cache: %q", got)
			}
			var accessError clientConfigAccessError
			if !errors.As(err, &accessError) {
				t.Fatalf("expected config access error, got %v", err)
			}
			if message := clientSetupErrorMessage(err); message != test.message {
				t.Fatalf("unexpected setup error message: %q", message)
			}
			if !clientHasSession() {
				t.Fatal("forbidden config request cleared the client session")
			}
			for _, path := range []string{clientSessionPath(), clientConfigPath(), cachePath()} {
				if _, statErr := os.Stat(path); statErr != nil {
					t.Fatalf("forbidden config request removed %s: %v", path, statErr)
				}
			}
		})
	}
}

func TestClientAuthenticationFailureAfterInvalidNotModifiedCacheClearsState(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(oldHome) })

	const session = "invalid-cache-session"
	const config = "mixed-port: 7890\n"
	if err := saveEncryptedFile(clientSessionPath(), []byte(session)); err != nil {
		t.Fatal(err)
	}
	envelope, err := json.Marshal(clientConfigCacheEnvelope{
		SessionID: clientSessionID(session),
		Etag:      "invalid-cache-etag",
		Config:    config,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := saveEncryptedFile(clientConfigPath(), envelope); err != nil {
		t.Fatal(err)
	}
	if err := saveConfigCache(config); err != nil {
		t.Fatal(err)
	}

	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if requests == 1 {
			if err := os.Remove(clientConfigPath()); err != nil {
				t.Error(err)
			}
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte("<html>unauthorized</html>"))
	}))
	defer srv.Close()

	_, err = fetchConfigFromClient(srv.URL, 0)
	var hardError clientHardError
	if !errors.As(err, &hardError) {
		t.Fatalf("expected authentication error, got %v", err)
	}
	if requests != 2 {
		t.Fatalf("unexpected request count: %d", requests)
	}
	if clientHasSession() {
		t.Fatal("rejected client session still exists")
	}
	for _, path := range []string{clientSessionPath(), clientConfigPath(), cachePath()} {
		if _, statErr := os.Stat(path); !errors.Is(statErr, os.ErrNotExist) {
			t.Fatalf("rejected client state still exists at %s: %v", path, statErr)
		}
	}
}

func TestClientServiceFailurePreservesLocalAuthenticationState(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(oldHome) })

	const session = "offline-cache-session"
	const config = "mixed-port: 7890\n"
	if err := saveEncryptedFile(clientSessionPath(), []byte(session)); err != nil {
		t.Fatal(err)
	}
	envelope, err := json.Marshal(clientConfigCacheEnvelope{
		SessionID: clientSessionID(session),
		Etag:      "offline-etag",
		Config:    config,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := saveEncryptedFile(clientConfigPath(), envelope); err != nil {
		t.Fatal(err)
	}
	if err := saveConfigCache(config); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]any{"ret": 0, "msg": "service unavailable"})
	}))
	defer srv.Close()

	got, err := fetchConfigFromClient(srv.URL, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got != config {
		t.Fatalf("unexpected offline config: %q", got)
	}
	if !clientHasSession() {
		t.Fatal("transient service failure cleared the client session")
	}
	for _, path := range []string{clientSessionPath(), clientConfigPath(), cachePath()} {
		if _, statErr := os.Stat(path); statErr != nil {
			t.Fatalf("transient service failure removed %s: %v", path, statErr)
		}
	}
}

func TestClientConfigStoresEncryptedAccountSummary(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(oldHome) })

	const session = "account-session"
	const config = "mixed-port: 7890\n"
	account := clientAccountInfo{RemainingBytes: 12_345_678, ExpireAt: 1_800_000_000}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case clientLoginEndpointPath:
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ret": 1, "msg": "ok", "session": session,
			})
		case clientConfigEndpointPath:
			var request map[string]string
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Fatal(err)
			}
			if _, present := request["response"]; present {
				t.Fatalf("unexpected config format selector: %#v", request)
			}
			if _, present := request["fmt"]; present {
				t.Fatalf("unexpected config format selector: %#v", request)
			}
			epk, err := base64.StdEncoding.DecodeString(request["epk"])
			if err != nil || len(epk) != 32 {
				t.Fatalf("bad epk: len=%d err=%v", len(epk), err)
			}
			plaintext, err := json.Marshal(clientConfigPayload{Config: config, Account: account})
			if err != nil {
				t.Fatal(err)
			}
			var epkArray [32]byte
			copy(epkArray[:], epk)
			cipher, err := box.SealAnonymous(nil, plaintext, &epkArray, rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ret": 1, "etag": "account-etag",
				"cipher": base64.StdEncoding.EncodeToString(cipher),
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	if err := clientLogin(srv.URL, "user@example.test", "password", ""); err != nil {
		t.Fatal(err)
	}
	got, err := fetchConfigFromClient(srv.URL, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got != config {
		t.Fatalf("unexpected config: %q", got)
	}
	if err := commitPendingClientConfigCache(); err != nil {
		t.Fatal(err)
	}
	var gotAccount clientAccountInfo
	if err := json.Unmarshal([]byte(clientAccountInfoJSON()), &gotAccount); err != nil {
		t.Fatal(err)
	}
	if gotAccount != account {
		t.Fatalf("unexpected account summary: %#v", gotAccount)
	}
	if plaintext, err := os.ReadFile(clientConfigPath()); err != nil {
		t.Fatal(err)
	} else if bytes.Contains(plaintext, []byte("remaining_bytes")) || bytes.Contains(plaintext, []byte(config)) {
		t.Fatal("account/config cache was stored in plaintext")
	}
}

func TestClientRuntimeDiagnosticsContainOnlyAggregateState(t *testing.T) {
	setupEnrollTestSecrets(t)
	oldHome := constant.Path.HomeDir()
	constant.SetHomeDir(t.TempDir())
	t.Cleanup(func() { constant.SetHomeDir(oldHome) })

	clientRuntimeDiagnosticsMu.Lock()
	oldDiagnostics := clientRuntimeDiagnostic
	clientRuntimeDiagnostic = clientRuntimeDiagnosticState{}
	clientRuntimeDiagnosticsMu.Unlock()
	t.Cleanup(func() {
		clientRuntimeDiagnosticsMu.Lock()
		clientRuntimeDiagnostic = oldDiagnostics
		clientRuntimeDiagnosticsMu.Unlock()
	})

	const session = "diagnostic-session"
	if err := saveEncryptedFile(clientSessionPath(), []byte(session)); err != nil {
		t.Fatal(err)
	}
	envelope, err := json.Marshal(clientConfigCacheEnvelope{
		SessionID: clientSessionID(session),
		Etag:      "opaque-etag",
		Config:    "mixed-port: 7890\n",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := saveEncryptedFile(clientConfigPath(), envelope); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(constant.Path.GeoIP(), []byte("geoip"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(constant.Path.GeoSite(), []byte("geosite"), 0600); err != nil {
		t.Fatal(err)
	}
	clientRecordRefreshStatus("2xx")
	clientRecordRefresh("online-updated", time.Now().Add(-50*time.Millisecond))
	clientRecordApply("success")
	clientRecordGeoUpdate("GEOIP", "success")

	payload := clientRuntimeDiagnosticsJSON()
	var diagnostics clientRuntimeDiagnostics
	if err := json.Unmarshal([]byte(payload), &diagnostics); err != nil {
		t.Fatal(err)
	}
	if !diagnostics.SessionPresent || !diagnostics.CachePresent {
		t.Fatalf("missing local state: %#v", diagnostics)
	}
	if diagnostics.LastRefreshResult != "online-updated" || diagnostics.LastRefreshStatus != "2xx" {
		t.Fatalf("unexpected refresh state: %#v", diagnostics)
	}
	if diagnostics.LastApplyResult != "success" || !diagnostics.GeoIP.Present || !diagnostics.GeoSite.Present {
		t.Fatalf("unexpected apply/geo state: %#v", diagnostics)
	}
	for _, forbidden := range []string{"diagnostic-session", "opaque-etag", "mixed-port", constant.Path.HomeDir()} {
		if strings.Contains(payload, forbidden) {
			t.Fatalf("diagnostics leaked %q: %s", forbidden, payload)
		}
	}
}

func TestDecodeClientConfigPayloadRejectsLegacyYAML(t *testing.T) {
	const yaml = "mixed-port: 7890\n"
	if _, _, err := decodeClientConfigPayload([]byte(yaml)); err == nil {
		t.Fatal("raw YAML payload was accepted")
	}
}

func TestClientLoginErrorsDoNotExposeEndpoint(t *testing.T) {
	raw := errors.New(`Post "https://private.example.test/hidden/login": connection refused`)
	if got := clientLoginErrorMessage(raw); got != "login failed" {
		t.Fatalf("unexpected redacted error: %q", got)
	}
	if got := clientLoginErrorMessage(clientLoginResponseError{message: "two-factor code is invalid"}); !strings.Contains(got, "two-factor") {
		t.Fatalf("safe server response was not preserved: %q", got)
	}
	if got := clientLoginErrorMessage(clientLoginResponseError{message: "visit https://private.example.test"}); got != "login failed" {
		t.Fatalf("unsafe server response was not redacted: %q", got)
	}
	if got := clientLoginErrorMessage(clientLoginNetworkError{}); got != "login network unavailable" {
		t.Fatalf("network error was not classified safely: %q", got)
	}
	if got := clientLoginErrorMessage(clientLoginServiceError{}); got != "login service unavailable" {
		t.Fatalf("service error was not classified safely: %q", got)
	}
	if got := clientLoginErrorMessage(clientLoginStorageError{}); got != "login local storage unavailable" {
		t.Fatalf("storage error was not classified safely: %q", got)
	}
}
