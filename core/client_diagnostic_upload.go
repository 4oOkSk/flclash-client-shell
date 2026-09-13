package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sync"
	"time"

	"golang.org/x/crypto/nacl/box"
)

const clientDiagnosticChunkBytes = 256 * 1024

type clientDiagnosticGrant struct {
	Endpoint string `json:"endpoint"`
	Token    string `json:"token"`
	Expires  int64  `json:"expires"`
}

var diagnosticGrantMu sync.Mutex
var diagnosticGrant clientDiagnosticGrant
var diagnosticGrantSession string
var diagnosticHTTP = clientHTTP
var diagnosticPath = regexp.MustCompile(`^/files/harborproxylogs/[a-f0-9]{32}\.jsonl$`)

func fetchDiagnosticGrant(endpoint, session string) (clientDiagnosticGrant, error) {
	var empty clientDiagnosticGrant
	target, err := clientURL(endpoint, clientConfigEndpointPath)
	if err != nil {
		return empty, err
	}
	public, private, err := box.GenerateKey(rand.Reader)
	if err != nil {
		return empty, err
	}
	body, _ := json.Marshal(map[string]interface{}{"epk": base64.StdEncoding.EncodeToString(public[:]), "diagnostic_only": true})
	req, err := newClientAPIRequest(http.MethodPost, target, body)
	if err != nil {
		return empty, err
	}
	req.Header.Set("Cookie", "client_session="+session)
	response, err := diagnosticHTTP().Do(req)
	if err != nil {
		return empty, errors.New("unavailable")
	}
	defer response.Body.Close()
	if response.StatusCode == 401 || response.StatusCode == 403 {
		return empty, errors.New("login-required")
	}
	if response.StatusCode != 200 {
		return empty, errors.New("unavailable")
	}
	wire, err := io.ReadAll(io.LimitReader(response.Body, 8193))
	var envelope struct {
		Ret    int    `json:"ret"`
		Cipher string `json:"cipher"`
	}
	if err != nil || len(wire) > 8192 || json.Unmarshal(wire, &envelope) != nil || envelope.Ret != 1 {
		return empty, errors.New("unavailable")
	}
	cipher, err := base64.StdEncoding.DecodeString(envelope.Cipher)
	if err != nil {
		return empty, errors.New("unavailable")
	}
	plaintext, ok := box.OpenAnonymous(nil, cipher, public, private)
	var payload struct {
		Diagnostics clientDiagnosticGrant `json:"diagnostics"`
	}
	if !ok || json.Unmarshal(plaintext, &payload) != nil {
		return empty, errors.New("unavailable")
	}
	grant := payload.Diagnostics
	parsed, err := url.Parse(grant.Endpoint)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Path != "/harborproxy-logdrop" || len(grant.Token) < 64 || len(grant.Token) > 512 || grant.Expires <= time.Now().Unix() || grant.Expires > time.Now().Unix()+43200 {
		return empty, errors.New("unavailable")
	}
	return grant, nil
}

func clientDiagnosticUpload(endpoint string, data json.RawMessage) string {
	failed := `{"ret":0,"error":"unavailable"}`
	var input struct {
		Action string `json:"action"`
	}
	if len(data) == 0 || len(data) > 360*1024 || json.Unmarshal(data, &input) != nil {
		return `{"ret":0,"error":"invalid"}`
	}
	switch input.Action {
	case "begin", "chunk", "finish", "status", "cancel":
	default:
		return `{"ret":0,"error":"invalid"}`
	}
	clientConfigMu.Lock()
	session, err := loadClientSession()
	clientConfigMu.Unlock()
	if err != nil || session == "" {
		return `{"ret":0,"error":"login-required"}`
	}
	diagnosticGrantMu.Lock()
	if diagnosticGrantSession != clientSessionID(session) || diagnosticGrant.Expires <= time.Now().Unix()+60 {
		diagnosticGrant, err = fetchDiagnosticGrant(endpoint, session)
		if err == nil {
			diagnosticGrantSession = clientSessionID(session)
		}
	}
	grant := diagnosticGrant
	diagnosticGrantMu.Unlock()
	if err != nil {
		if err.Error() == "login-required" {
			return `{"ret":0,"error":"login-required"}`
		}
		return failed
	}
	req, err := http.NewRequest(http.MethodPost, grant.Endpoint, bytes.NewReader(data))
	if err != nil {
		return failed
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+grant.Token)
	response, err := diagnosticHTTP().Do(req)
	if err != nil {
		return failed
	}
	defer response.Body.Close()
	if response.StatusCode == 401 {
		diagnosticGrantMu.Lock()
		if diagnosticGrant.Token == grant.Token {
			diagnosticGrant.Expires = 0
		}
		diagnosticGrantMu.Unlock()
		return `{"ret":0,"error":"login-required"}`
	}
	if response.StatusCode == 429 {
		return `{"ret":0,"error":"rate-limited"}`
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return failed
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 8193))
	var result map[string]interface{}
	if err != nil || len(body) > 8192 || json.Unmarshal(body, &result) != nil {
		return failed
	}
	if result["state"] == "ready" {
		path, ok := result["path"].(string)
		if !ok || !diagnosticPath.MatchString(path) {
			return failed
		}
		origin, _ := url.Parse(grant.Endpoint)
		origin.Path = path
		result["url"] = origin.String()
		delete(result, "path")
	}
	clean, err := json.Marshal(result)
	if err != nil {
		return failed
	}
	return string(clean)
}
