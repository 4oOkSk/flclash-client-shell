package main

// PATCH(ops): 私有客户端"入册"——解不透明乱码 blob → 一次性握手从面板拉取配置 → 验签+解密。
// 配置全程只在内存(返回字符串交给内存喂配置路径 applyConfig{Config:...})。
// 与面板(PHP sodium_compat)、Go mock 面板同一线格式: sealed box(crypto_box_seal) + Ed25519。

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/constant"
	"golang.org/x/crypto/nacl/box"
	"golang.org/x/crypto/nacl/secretbox"
)

// 入册密钥由构建期注入, 不进入 Git:
//
//	-ldflags "-X main.enrollClientBlobPriv=... -X main.enrollClientBlobPub=..."
//	-ldflags "-X main.enrollPanelSigPub=..."
var (
	enrollClientBlobPriv  = ""
	enrollClientBlobPub   = ""
	enrollPanelSigPub     = ""
	runtimeCacheKey       *[32]byte
	runtimeCacheKeySource = "file-fallback"
	cacheKeyMu            sync.RWMutex
)

// 可测试注入点: 由 (host, path) 生成请求 URL。默认 https; blob 里 h 若自带 scheme(如本地 mock 用 http)则原样用。
var enrollURLBuilder = func(h, p string) string {
	if strings.HasPrefix(h, "http://") || strings.HasPrefix(h, "https://") {
		return h + p
	}
	return "https://" + h + p
}

type enrollPayload struct {
	H  string `json:"h"`
	P  string `json:"p"`
	T  string `json:"t"`
	SK string `json:"sk"`
}

func b64d(s string) ([]byte, error) { return base64.StdEncoding.DecodeString(strings.TrimSpace(s)) }
func arr32(b []byte) *[32]byte      { var a [32]byte; copy(a[:], b); return &a }

const (
	enrollModeLegacy            = ""
	enrollModeClientLogin       = "client-login"
	enrollModeClientSetup       = "client-setup"
	enrollModeClientState       = "client-state"
	enrollModeClientInfo        = "client-info"
	enrollModeClientDiagnostics = "client-diagnostics"
	enrollModeClientSecureStore = "client-secure-storage"
	enrollModeClientClear       = "client-clear"
)

// fetchConfigFromEnroll: 缓存未过期则直接读加密缓存; 过期后在线拉取(成功则更新缓存)。
// 在线失败时仍回落上次成功的加密缓存(离线可用)。
func fetchConfigFromEnroll(blob string, refreshInterval time.Duration) (string, error) {
	if refreshInterval > 0 {
		if cached, cerr := loadFreshConfigCache(refreshInterval); cerr == nil && cached != "" {
			return cached, nil
		}
	}
	cfg, err := fetchConfigOnline(blob)
	if err == nil {
		_ = saveConfigCache(cfg) // best-effort, 失败不影响本次
		return cfg, nil
	}
	if cached, cerr := loadConfigCache(); cerr == nil && cached != "" {
		return cached, nil // 在线失败, 用上次成功配置(仍只进内存)
	}
	return "", err
}

// loadFreshConfigCache: 仅当密文缓存 mtime 未超过 refreshInterval 时返回。
func loadFreshConfigCache(refreshInterval time.Duration) (string, error) {
	info, err := os.Stat(cachePath())
	if err != nil {
		return "", err
	}
	if time.Since(info.ModTime()) >= refreshInterval {
		return "", errors.New("cache expired")
	}
	return loadConfigCache()
}

// cacheKeyArr returns the per-device key. Strong platforms inject a key
// protected by the OS secure store. Other platforms use a random 0600 file.
func cacheKeyArr() (*[32]byte, error) {
	cacheKeyMu.RLock()
	if runtimeCacheKey != nil {
		key := *runtimeCacheKey
		cacheKeyMu.RUnlock()
		return &key, nil
	}
	cacheKeyMu.RUnlock()

	k, err := loadOrCreateLocalCacheKey()
	if err != nil {
		return nil, err
	}
	var a [32]byte
	copy(a[:], k)
	return &a, nil
}

func configureRuntimeCacheKey(encoded, source string) {
	cacheKeyMu.Lock()
	runtimeCacheKey = nil
	runtimeCacheKeySource = "file-fallback"
	if decoded, err := b64d(encoded); err == nil && len(decoded) == 32 {
		var key [32]byte
		copy(key[:], decoded)
		runtimeCacheKey = &key
		if isAllowedCacheKeySource(source) {
			runtimeCacheKeySource = source
		} else {
			runtimeCacheKeySource = "system-secure"
		}
	}
	cacheKeyMu.Unlock()
}

func isAllowedCacheKeySource(source string) bool {
	switch source {
	case "android-keystore", "windows-dpapi", "macos-data-protection-keychain", "macos-file-fallback", "linux-secret-service":
		return true
	default:
		return false
	}
}

func currentCacheKeySource() string {
	cacheKeyMu.RLock()
	defer cacheKeyMu.RUnlock()
	return runtimeCacheKeySource
}

func cachePath() string    { return filepath.Join(constant.Path.HomeDir(), ".econf.bin") }
func cacheKeyPath() string { return filepath.Join(constant.Path.HomeDir(), ".ekey.bin") }

func loadOrCreateLocalCacheKey() ([]byte, error) {
	path := cacheKeyPath()
	if data, err := os.ReadFile(path); err == nil && len(data) == 32 {
		return data, nil
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	if err := writeSecretFile(path, key); err != nil {
		return nil, err
	}
	return key, nil
}

// saveConfigCache: secretbox 加密配置 → 写 nonce(24)||box 到数据目录(0600, 磁盘只有密文)
func saveConfigCache(config string) error {
	key, err := cacheKeyArr()
	if err != nil {
		return err
	}
	sealed, err := sealSecretboxPayload([]byte(config), key)
	if err != nil {
		return err
	}
	return writeSecretFile(cachePath(), sealed)
}

// loadConfigCache: 读密文 → secretbox 解密(仅内存)
func loadConfigCache() (string, error) {
	key, err := cacheKeyArr()
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(cachePath())
	if err != nil {
		return "", err
	}
	opened, ok := openSecretboxPayload(data, key)
	if !ok {
		return "", errors.New("cache decrypt failed")
	}
	return string(opened), nil
}

func saveEncryptedFile(path string, payload []byte) error {
	key, err := cacheKeyArr()
	if err != nil {
		return err
	}
	sealed, err := sealSecretboxPayload(payload, key)
	if err != nil {
		return err
	}
	return writeSecretFile(path, sealed)
}

func loadEncryptedFile(path string) ([]byte, error) {
	key, err := cacheKeyArr()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	opened, ok := openSecretboxPayload(data, key)
	if !ok {
		return nil, errors.New("cache decrypt failed")
	}
	return opened, nil
}

func sealSecretboxPayload(payload []byte, key *[32]byte) ([]byte, error) {
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	return secretbox.Seal(nonce[:], payload, &nonce, key), nil
}

func openSecretboxPayload(data []byte, key *[32]byte) ([]byte, bool) {
	if key == nil || len(data) < 24 {
		return nil, false
	}
	var nonce [24]byte
	copy(nonce[:], data[:24])
	return secretbox.Open(nil, data[24:], &nonce, key)
}

func writeSecretFile(path string, payload []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}
	// The desktop core may be setuid root for TUN setup. Keep user-owned cache
	// files accessible after restart while retaining mode 0600.
	if os.Geteuid() == 0 && os.Getuid() != 0 {
		if err := tmp.Chown(os.Getuid(), os.Getgid()); err != nil {
			tmp.Close()
			return err
		}
	}
	if _, err := tmp.Write(payload); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// fetchConfigOnline: 输入乱码 blob, 在线握手拉取配置 YAML 字符串(仅内存)。
func fetchConfigOnline(blob string) (string, error) {
	cbPriv, err := b64d(enrollClientBlobPriv)
	if err != nil {
		return "", err
	}
	cbPub, err := b64d(enrollClientBlobPub)
	if err != nil {
		return "", err
	}
	sigPub, err := b64d(enrollPanelSigPub)
	if err != nil {
		return "", err
	}

	// 1) 解乱码 blob
	sealed, err := b64d(blob)
	if err != nil {
		return "", errors.New("blob base64 decode failed")
	}
	opened, ok := box.OpenAnonymous(nil, sealed, arr32(cbPub), arr32(cbPriv))
	if !ok {
		return "", errors.New("blob decrypt failed")
	}
	var ep enrollPayload
	if err := json.Unmarshal(opened, &ep); err != nil {
		return "", errors.New("blob payload malformed")
	}
	if ep.H == "" || ep.T == "" {
		return "", errors.New("blob missing host/token")
	}
	// blob 内也可带 per-blob 验签公钥; 优先用它(支持轮换), 否则用内嵌
	if ep.SK != "" {
		if b, e := b64d(ep.SK); e == nil && len(b) == ed25519.PublicKeySize {
			sigPub = b
		}
	}

	// 2) ephemeral + 请求
	epk, esk, err := box.GenerateKey(rand.Reader)
	if err != nil {
		return "", err
	}
	reqBody, _ := json.Marshal(map[string]string{
		"t":   ep.T,
		"epk": base64.StdEncoding.EncodeToString(epk[:]),
		"fmt": "mihomo",
	})
	url := enrollURLBuilder(ep.H, ep.P)
	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Post(url, "application/json", bytes.NewReader(reqBody))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", errors.New("panel status " + resp.Status)
	}
	wire, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", err
	}
	var fr struct {
		Ver    string `json:"ver"`
		Cipher string `json:"cipher"`
		Sig    string `json:"sig"`
	}
	if err := json.Unmarshal(wire, &fr); err != nil {
		return "", errors.New("panel resp malformed")
	}

	// 3) 验签
	cipher, err := b64d(fr.Cipher)
	if err != nil {
		return "", err
	}
	sig, err := b64d(fr.Sig)
	if err != nil {
		return "", err
	}
	if !ed25519.Verify(sigPub, append([]byte(fr.Ver), cipher...), sig) {
		return "", errors.New("signature verify failed")
	}

	// 4) 解密配置(ephemeral)
	config, ok := box.OpenAnonymous(nil, cipher, epk, esk)
	if !ok {
		return "", errors.New("config decrypt failed")
	}
	return string(config), nil
}
