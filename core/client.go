package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/constant"
	"golang.org/x/crypto/nacl/box"
)

type clientHardError struct {
	message string
}

func (e clientHardError) Error() string { return e.message }

type clientLoginResponseError struct {
	message string
}

func (e clientLoginResponseError) Error() string { return e.message }

type clientLoginNetworkError struct{}

func (clientLoginNetworkError) Error() string { return "login network unavailable" }

type clientLoginServiceError struct{}

func (clientLoginServiceError) Error() string { return "login service unavailable" }

type clientLoginStorageError struct{}

func (clientLoginStorageError) Error() string { return "login local storage unavailable" }

const clientLoginRequiredMessage = "client login required"

type clientConfigCacheEnvelope struct {
	SessionID string             `json:"session_id"`
	Etag      string             `json:"etag"`
	Config    string             `json:"config"`
	Account   *clientAccountInfo `json:"account,omitempty"`
}

type clientAccountInfo struct {
	RemainingBytes int64 `json:"remaining_bytes"`
	ExpireAt       int64 `json:"expire_at"`
}

type clientConfigPayload struct {
	Config  string            `json:"config"`
	Account clientAccountInfo `json:"account"`
}

var pendingClientConfigCache *clientConfigCacheEnvelope
var clientConfigMu sync.Mutex

type clientRuntimeDiagnosticState struct {
	LastRefreshAt         int64
	LastRefreshResult     string
	LastRefreshStatus     string
	LastRefreshDurationMs int64
	LastApplyAt           int64
	LastApplyResult       string
	LastGeoUpdateAt       int64
	LastGeoUpdateType     string
	LastGeoUpdateResult   string
}

type clientDataFileDiagnostic struct {
	Present    bool  `json:"present"`
	AgeSeconds int64 `json:"age_seconds"`
	SizeBytes  int64 `json:"size_bytes"`
}

type clientRuntimeDiagnostics struct {
	SessionPresent        bool                     `json:"session_present"`
	CachePresent          bool                     `json:"cache_present"`
	CacheAgeSeconds       int64                    `json:"cache_age_seconds"`
	LastRefreshAt         int64                    `json:"last_refresh_at"`
	LastRefreshResult     string                   `json:"last_refresh_result"`
	LastRefreshStatus     string                   `json:"last_refresh_status"`
	LastRefreshDurationMs int64                    `json:"last_refresh_duration_ms"`
	LastApplyAt           int64                    `json:"last_apply_at"`
	LastApplyResult       string                   `json:"last_apply_result"`
	CoreVersion           string                   `json:"core_version"`
	GeoIP                 clientDataFileDiagnostic `json:"geoip"`
	GeoSite               clientDataFileDiagnostic `json:"geosite"`
	LastGeoUpdateAt       int64                    `json:"last_geo_update_at"`
	LastGeoUpdateType     string                   `json:"last_geo_update_type"`
	LastGeoUpdateResult   string                   `json:"last_geo_update_result"`
	SecureStorage         string                   `json:"secure_storage"`
}

var clientRuntimeDiagnosticsMu sync.Mutex
var clientRuntimeDiagnostic clientRuntimeDiagnosticState

func clientSessionPath() string { return filepath.Join(constant.Path.HomeDir(), ".esession.bin") }
func clientConfigPath() string  { return filepath.Join(constant.Path.HomeDir(), ".eclientconf.bin") }

func clientURL(endpoint, path string) (string, error) {
	endpoint = strings.TrimRight(strings.TrimSpace(endpoint), "/")
	if endpoint == "" {
		return "", errors.New("client endpoint is empty")
	}
	if !strings.Contains(endpoint, "://") {
		endpoint = "https://" + endpoint
	}
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Host == "" {
		return "", errors.New("client endpoint is invalid")
	}
	if parsed.Scheme != "https" && !isLocalClientEndpoint(parsed.Hostname()) {
		return "", errors.New("client endpoint must use https")
	}
	return endpoint + path, nil
}

func isLocalClientEndpoint(host string) bool {
	return host == "127.0.0.1" || host == "::1" || strings.EqualFold(host, "localhost")
}

func clientHTTP() *http.Client {
	return &http.Client{
		Timeout: 20 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func clientLogin(endpoint, email, password, code string) error {
	requestURL, err := clientURL(endpoint, clientLoginEndpointPath)
	if err != nil {
		return err
	}
	body, err := json.Marshal(map[string]string{
		"email":    strings.TrimSpace(email),
		"password": password,
		"code":     strings.TrimSpace(code),
	})
	if err != nil {
		return err
	}
	req, err := newClientAPIRequest(http.MethodPost, requestURL, body)
	if err != nil {
		return err
	}
	resp, err := clientHTTP().Do(req)
	if err != nil {
		return clientLoginNetworkError{}
	}
	defer resp.Body.Close()
	wire, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return clientLoginServiceError{}
	}
	var lr struct {
		Ret     int    `json:"ret"`
		Msg     string `json:"msg"`
		Session string `json:"session"`
	}
	if err := json.Unmarshal(wire, &lr); err != nil {
		return clientLoginServiceError{}
	}
	if resp.StatusCode != 200 || lr.Ret != 1 || lr.Session == "" {
		if lr.Msg != "" {
			return clientLoginResponseError{message: lr.Msg}
		}
		return clientLoginServiceError{}
	}
	if err := clearClientConfigState(); err != nil {
		return clientLoginStorageError{}
	}
	if err := removeClientFiles(clientSessionPath()); err != nil {
		return clientLoginStorageError{}
	}
	if err := saveEncryptedFile(clientSessionPath(), []byte(lr.Session)); err != nil {
		return clientLoginStorageError{}
	}
	return nil
}

func clientHasSession() bool {
	session, err := loadClientSession()
	return err == nil && session != ""
}

func clientClear(endpoint string) error {
	// Logout is deliberately best-effort: losing the network must never trap
	// the encrypted local session/config on the device. The server endpoint can
	// revoke the session when reachable; local deletion always follows.
	if session, err := loadClientSession(); err == nil && session != "" {
		_ = clientLogoutOnline(endpoint, session)
	}
	pendingClientConfigCache = nil
	return removeClientFiles(
		clientSessionPath(),
		clientConfigPath(),
		cachePath(),
		cacheKeyPath(),
	)
}

func clientLogoutOnline(endpoint, session string) error {
	requestURL, err := clientURL(endpoint, clientLogoutEndpointPath)
	if err != nil {
		return err
	}
	req, err := newClientAPIRequest(http.MethodPost, requestURL, []byte("{}"))
	if err != nil {
		return err
	}
	req.Header.Set("Cookie", "client_session="+session)
	resp, err := clientHTTP().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return errors.New("client logout failed")
	}
	return nil
}

func loadClientSession() (string, error) {
	data, err := loadEncryptedFile(clientSessionPath())
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func fetchConfigFromClient(endpoint string, refreshInterval time.Duration) (string, error) {
	started := time.Now()
	refreshResult := "failed"
	clientRecordRefreshStatus("not-attempted")
	defer func() {
		clientRecordRefresh(refreshResult, started)
	}()
	pendingClientConfigCache = nil
	session, err := loadClientSession()
	if err != nil || session == "" {
		refreshResult = "login-required"
		return "", clientHardError{message: "client login required"}
	}
	sessionID := clientSessionID(session)

	if refreshInterval > 0 {
		if cached, _, err := loadFreshClientConfigCache(refreshInterval, sessionID); err == nil && cached != "" {
			clientRecordRefreshStatus("local-cache")
			refreshResult = "cache-fresh"
			return cached, nil
		}
	}

	etag := ""
	if _, cachedEtag, err := loadClientConfigCache(sessionID); err == nil {
		etag = cachedEtag
	}

	cfg, account, nextEtag, notModified, err := fetchClientConfigOnline(endpoint, session, etag)
	if err == nil {
		if notModified {
			envelope, cerr := loadClientConfigCacheEnvelope(sessionID)
			if cerr == nil && envelope.Config != "" {
				if nextEtag == "" {
					nextEtag = envelope.Etag
				}
				pendingClientConfigCache = &clientConfigCacheEnvelope{
					SessionID: sessionID,
					Etag:      nextEtag,
					Config:    envelope.Config,
					Account:   envelope.Account,
				}
				refreshResult = "online-not-modified"
				return envelope.Config, nil
			}
			cfg, account, nextEtag, notModified, err = fetchClientConfigOnline(endpoint, session, "")
		}
		if err == nil && notModified {
			err = errors.New("client config cache invalid")
		}
		if err == nil {
			pendingClientConfigCache = &clientConfigCacheEnvelope{
				SessionID: sessionID,
				Etag:      nextEtag,
				Config:    cfg,
				Account:   account,
			}
			refreshResult = "online-updated"
			return cfg, nil
		}
	}
	if _, ok := err.(clientHardError); ok {
		if clearErr := clearClientAuthenticationState(); clearErr != nil {
			refreshResult = "authentication-clear-failed"
		} else {
			refreshResult = "authentication-failed"
		}
		return "", err
	}
	if cached, _, cerr := loadClientConfigCache(sessionID); cerr == nil && cached != "" {
		refreshResult = "offline-cache"
		return cached, nil
	}
	return "", err
}

func commitPendingClientConfigCache() error {
	if pendingClientConfigCache == nil {
		return nil
	}
	payload, err := json.Marshal(pendingClientConfigCache)
	if err != nil {
		return err
	}
	if err := saveEncryptedFile(clientConfigPath(), payload); err != nil {
		return err
	}
	pendingClientConfigCache = nil
	return nil
}

func loadFreshClientConfigCache(refreshInterval time.Duration, sessionID string) (string, string, error) {
	info, err := os.Stat(clientConfigPath())
	if err != nil {
		return "", "", err
	}
	if time.Since(info.ModTime()) >= refreshInterval {
		return "", "", errors.New("cache expired")
	}
	return loadClientConfigCache(sessionID)
}

func loadClientConfigCache(sessionID string) (string, string, error) {
	envelope, err := loadClientConfigCacheEnvelope(sessionID)
	if err != nil {
		return "", "", err
	}
	return envelope.Config, envelope.Etag, nil
}

func loadClientConfigCacheEnvelope(sessionID string) (*clientConfigCacheEnvelope, error) {
	payload, err := loadEncryptedFile(clientConfigPath())
	if err != nil {
		return nil, err
	}
	var envelope clientConfigCacheEnvelope
	if err := json.Unmarshal(payload, &envelope); err != nil {
		return nil, err
	}
	if envelope.SessionID == "" || !strings.EqualFold(envelope.SessionID, sessionID) {
		return nil, errors.New("cache session mismatch")
	}
	if envelope.Config == "" {
		return nil, errors.New("cache config empty")
	}
	return &envelope, nil
}

func clientAccountInfoJSON() string {
	session, err := loadClientSession()
	if err != nil || session == "" {
		return ""
	}
	envelope, err := loadClientConfigCacheEnvelope(clientSessionID(session))
	if err != nil || envelope.Account == nil {
		return ""
	}
	payload, err := json.Marshal(envelope.Account)
	if err != nil {
		return ""
	}
	return string(payload)
}

func clearClientConfigState() error {
	pendingClientConfigCache = nil
	return removeClientFiles(clientConfigPath(), cachePath())
}

func clearClientAuthenticationState() error {
	pendingClientConfigCache = nil
	return removeClientFiles(
		clientSessionPath(),
		clientConfigPath(),
		cachePath(),
	)
}

func removeClientFiles(paths ...string) error {
	var errs []error
	for _, path := range paths {
		err := os.Remove(path)
		if err == nil || errors.Is(err, os.ErrNotExist) {
			continue
		}
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

func clientSessionID(session string) string {
	sum := sha256.Sum256([]byte(session))
	return hex.EncodeToString(sum[:])
}

func fetchClientConfigOnline(endpoint, session, etag string) (string, *clientAccountInfo, string, bool, error) {
	requestURL, err := clientURL(endpoint, clientConfigEndpointPath)
	if err != nil {
		return "", nil, "", false, err
	}
	epk, esk, err := box.GenerateKey(rand.Reader)
	if err != nil {
		return "", nil, "", false, err
	}
	body, err := json.Marshal(map[string]string{
		"epk":  base64.StdEncoding.EncodeToString(epk[:]),
		"etag": etag,
	})
	if err != nil {
		return "", nil, "", false, err
	}
	req, err := newClientAPIRequest(http.MethodPost, requestURL, body)
	if err != nil {
		return "", nil, "", false, err
	}
	req.Header.Set("Cookie", "client_session="+session)
	if etag != "" {
		req.Header.Set("If-None-Match", `"`+etag+`"`)
	}

	resp, err := clientHTTP().Do(req)
	if err != nil {
		clientRecordRefreshStatus("network-error")
		return "", nil, "", false, err
	}
	defer resp.Body.Close()
	clientRecordRefreshStatus(clientHTTPStatusCategory(resp.StatusCode))
	if resp.StatusCode == http.StatusNotModified {
		return "", nil, strings.Trim(resp.Header.Get("ETag"), `"`), true, nil
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		wire, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		var authResponse struct {
			Msg string `json:"msg"`
		}
		if json.Unmarshal(wire, &authResponse) == nil && authResponse.Msg != "" {
			return "", nil, "", false, clientHardError{message: authResponse.Msg}
		}
		return "", nil, "", false, clientHardError{message: resp.Status}
	}
	wire, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", nil, "", false, err
	}
	var fr struct {
		Ret    int    `json:"ret"`
		Msg    string `json:"msg"`
		Etag   string `json:"etag"`
		Cipher string `json:"cipher"`
	}
	if err := json.Unmarshal(wire, &fr); err != nil {
		return "", nil, "", false, errors.New("client config response malformed")
	}
	if resp.StatusCode != 200 || fr.Ret != 1 || fr.Cipher == "" {
		if fr.Msg != "" {
			return "", nil, "", false, errors.New(fr.Msg)
		}
		return "", nil, "", false, errors.New("client config failed")
	}
	cipher, err := b64d(fr.Cipher)
	if err != nil {
		return "", nil, "", false, err
	}
	plaintext, ok := box.OpenAnonymous(nil, cipher, epk, esk)
	if !ok {
		return "", nil, "", false, errors.New("client config decrypt failed")
	}
	config, account, err := decodeClientConfigPayload(plaintext)
	if err != nil {
		return "", nil, "", false, err
	}
	return config, account, fr.Etag, false, nil
}

func decodeClientConfigPayload(plaintext []byte) (string, *clientAccountInfo, error) {
	var payload clientConfigPayload
	if err := json.Unmarshal(plaintext, &payload); err != nil {
		return "", nil, errors.New("client config payload malformed")
	}
	if strings.TrimSpace(payload.Config) == "" {
		return "", nil, errors.New("client config payload empty")
	}
	if payload.Account.RemainingBytes < 0 || payload.Account.ExpireAt < 0 {
		return "", nil, errors.New("client account payload invalid")
	}
	return payload.Config, &payload.Account, nil
}

func clientLoginErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	if responseErr, ok := err.(clientLoginResponseError); ok {
		switch responseErr.message {
		case "missing credentials", "too many attempts", "email or password is invalid", "two-factor code is invalid":
			return responseErr.message
		}
	}
	switch err.(type) {
	case clientLoginNetworkError:
		return "login network unavailable"
	case clientLoginServiceError:
		return "login service unavailable"
	case clientLoginStorageError:
		return "login local storage unavailable"
	}
	return "login failed"
}

func clientSetupErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	if _, ok := err.(clientHardError); ok {
		// Keep a stable machine-readable result for the login gate. Server error
		// wording may change or be localized; it must not turn transient config
		// failures into an endless password prompt.
		return clientLoginRequiredMessage
	}
	return "client config update failed"
}

func clientHTTPStatusCategory(status int) string {
	switch {
	case status >= 200 && status < 300:
		return "2xx"
	case status >= 300 && status < 400:
		return "3xx"
	case status >= 400 && status < 500:
		return "4xx"
	case status >= 500 && status < 600:
		return "5xx"
	default:
		return "other"
	}
}

func clientRecordRefreshStatus(status string) {
	clientRuntimeDiagnosticsMu.Lock()
	clientRuntimeDiagnostic.LastRefreshStatus = status
	clientRuntimeDiagnosticsMu.Unlock()
}

func clientRecordRefresh(result string, started time.Time) {
	clientRuntimeDiagnosticsMu.Lock()
	clientRuntimeDiagnostic.LastRefreshAt = time.Now().Unix()
	clientRuntimeDiagnostic.LastRefreshResult = result
	clientRuntimeDiagnostic.LastRefreshDurationMs = time.Since(started).Milliseconds()
	clientRuntimeDiagnosticsMu.Unlock()
}

func clientRecordApply(result string) {
	clientRuntimeDiagnosticsMu.Lock()
	clientRuntimeDiagnostic.LastApplyAt = time.Now().Unix()
	clientRuntimeDiagnostic.LastApplyResult = result
	clientRuntimeDiagnosticsMu.Unlock()
}

func clientRecordGeoUpdate(geoType, result string) {
	clientRuntimeDiagnosticsMu.Lock()
	clientRuntimeDiagnostic.LastGeoUpdateAt = time.Now().Unix()
	clientRuntimeDiagnostic.LastGeoUpdateType = geoType
	clientRuntimeDiagnostic.LastGeoUpdateResult = result
	clientRuntimeDiagnosticsMu.Unlock()
}

func clientFileDiagnostic(path string) clientDataFileDiagnostic {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return clientDataFileDiagnostic{AgeSeconds: -1}
	}
	age := time.Since(info.ModTime()).Seconds()
	if age < 0 {
		age = 0
	}
	return clientDataFileDiagnostic{
		Present:    true,
		AgeSeconds: int64(age),
		SizeBytes:  info.Size(),
	}
}

func clientRuntimeDiagnosticsJSON() string {
	clientRuntimeDiagnosticsMu.Lock()
	state := clientRuntimeDiagnostic
	clientRuntimeDiagnosticsMu.Unlock()

	cacheInfo, cacheErr := os.Stat(clientConfigPath())
	cacheAge := int64(-1)
	cachePresent := cacheErr == nil && !cacheInfo.IsDir()
	if cachePresent {
		age := time.Since(cacheInfo.ModTime()).Seconds()
		if age < 0 {
			age = 0
		}
		cacheAge = int64(age)
	}
	diagnostics := clientRuntimeDiagnostics{
		SessionPresent:        clientHasSession(),
		CachePresent:          cachePresent,
		CacheAgeSeconds:       cacheAge,
		LastRefreshAt:         state.LastRefreshAt,
		LastRefreshResult:     state.LastRefreshResult,
		LastRefreshStatus:     state.LastRefreshStatus,
		LastRefreshDurationMs: state.LastRefreshDurationMs,
		LastApplyAt:           state.LastApplyAt,
		LastApplyResult:       state.LastApplyResult,
		CoreVersion:           constant.Version,
		GeoIP:                 clientFileDiagnostic(constant.Path.GeoIP()),
		GeoSite:               clientFileDiagnostic(constant.Path.GeoSite()),
		LastGeoUpdateAt:       state.LastGeoUpdateAt,
		LastGeoUpdateType:     state.LastGeoUpdateType,
		LastGeoUpdateResult:   state.LastGeoUpdateResult,
		SecureStorage:         currentCacheKeySource(),
	}
	payload, err := json.Marshal(diagnostics)
	if err != nil {
		return ""
	}
	return string(payload)
}
