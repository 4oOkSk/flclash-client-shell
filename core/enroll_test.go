package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/constant"
	"golang.org/x/crypto/nacl/box"
)

func TestWriteSecretFileKeepsModeAndReplacesAtomically(t *testing.T) {
	path := filepath.Join(t.TempDir(), "secret.bin")
	if err := writeSecretFile(path, []byte("first")); err != nil {
		t.Fatal(err)
	}
	if err := writeSecretFile(path, []byte("second")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "second" {
		t.Fatalf("unexpected payload: %q", data)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0600 {
		t.Fatalf("unexpected mode: %o", info.Mode().Perm())
	}
}

func TestEnrollRoundtrip(t *testing.T) {
	sigPriv := setupEnrollTestSecrets(t)

	const secretServer = "server.example"
	const secretDomain = "sub-hidden-x.example.net"
	sampleConfig := "mixed-port: 7890\nproxies:\n  - {name: HK01, type: vless, server: " + secretServer + ", port: 443}\n"
	token := "tok_test123"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]string
		json.NewDecoder(r.Body).Decode(&req)
		if req["t"] != token {
			w.WriteHeader(404)
			return
		}
		epk, _ := base64.StdEncoding.DecodeString(req["epk"])
		var epkArr [32]byte
		copy(epkArr[:], epk)
		cfg := []byte(sampleConfig)
		sum := sha256.Sum256(cfg)
		ver := hex.EncodeToString(sum[:8])
		cipher, _ := box.SealAnonymous(nil, cfg, &epkArr, rand.Reader)
		sig := ed25519.Sign(sigPriv, append([]byte(ver), cipher...))
		json.NewEncoder(w).Encode(map[string]string{
			"ver": ver, "cipher": base64.StdEncoding.EncodeToString(cipher), "sig": base64.StdEncoding.EncodeToString(sig),
		})
	}))
	defer srv.Close()

	enrollURLBuilder = func(h, p string) string { return srv.URL + p }

	cbPub, _ := b64d(enrollClientBlobPub)
	ep := enrollPayload{H: secretDomain, P: "/c/x", T: token, SK: enrollPanelSigPub}
	epJSON, _ := json.Marshal(ep)
	sealed, _ := box.SealAnonymous(nil, epJSON, arr32(cbPub), rand.Reader)
	blob := base64.StdEncoding.EncodeToString(sealed)

	if strings.Contains(blob, secretDomain) || strings.Contains(blob, secretServer) {
		t.Fatal("blob leaks plaintext")
	}

	cfg, err := fetchConfigFromEnroll(blob, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(cfg, secretServer) {
		t.Fatalf("config missing server: %s", cfg)
	}
	t.Logf("OK: 入册拉取成功, 配置含服务器 %s (len=%d), blob无明文", secretServer, len(cfg))
}

func TestEnrollFreshCacheSkipsOnline(t *testing.T) {
	const cachedConfig = "mixed-port: 7890\n"
	setupEnrollTestSecrets(t)
	homeDir := t.TempDir()
	constant.SetHomeDir(homeDir)
	if err := saveConfigCache(cachedConfig); err != nil {
		t.Fatal(err)
	}

	calls := 0
	oldBuilder := enrollURLBuilder
	enrollURLBuilder = func(h, p string) string {
		calls++
		return oldBuilder(h, p)
	}
	defer func() {
		enrollURLBuilder = oldBuilder
	}()

	cfg, err := fetchConfigFromEnroll("not-a-real-blob", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if cfg != cachedConfig {
		t.Fatalf("unexpected cached config: %q", cfg)
	}
	if calls != 0 {
		t.Fatalf("fresh cache should not go online, calls=%d", calls)
	}
}

func setupEnrollTestSecrets(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	oldClientPriv := enrollClientBlobPriv
	oldClientPub := enrollClientBlobPub
	oldPanelSigPub := enrollPanelSigPub
	t.Cleanup(func() {
		enrollClientBlobPriv = oldClientPriv
		enrollClientBlobPub = oldClientPub
		enrollPanelSigPub = oldPanelSigPub
	})

	clientPub, clientPriv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sigPub, sigPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	enrollClientBlobPriv = base64.StdEncoding.EncodeToString(clientPriv[:])
	enrollClientBlobPub = base64.StdEncoding.EncodeToString(clientPub[:])
	enrollPanelSigPub = base64.StdEncoding.EncodeToString(sigPub)
	return sigPriv
}

func TestAllowedCacheKeySources(t *testing.T) {
	allowed := []string{
		"android-keystore",
		"windows-dpapi",
		"macos-data-protection-keychain",
		"macos-file-fallback",
		"linux-secret-service",
	}
	for _, source := range allowed {
		if !isAllowedCacheKeySource(source) {
			t.Fatalf("expected secure storage source %q to be allowed", source)
		}
	}
	if isAllowedCacheKeySource("file-fallback") {
		t.Fatal("generic file fallback must not be reported as a system secure source")
	}
}
