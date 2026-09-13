package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
)

const clientDiagnosticChunkBytes = 256 * 1024

func clientDiagnosticUpload(endpoint string, data json.RawMessage) string {
	failed := `{"ret":0,"error":"unavailable"}`
	if len(data) == 0 || len(data) > 360*1024 || !json.Valid(data) {
		return `{"ret":0,"error":"invalid"}`
	}
	var request map[string]json.RawMessage
	if json.Unmarshal(data, &request) != nil {
		return `{"ret":0,"error":"invalid"}`
	}
	var action string
	if json.Unmarshal(request["action"], &action) != nil {
		return `{"ret":0,"error":"invalid"}`
	}
	switch action {
	case "begin", "chunk", "finish", "status", "cancel":
	default:
		return `{"ret":0,"error":"invalid"}`
	}
	target, err := clientURL(endpoint, "/diagnostics")
	if err != nil {
		return failed
	}
	clientConfigMu.Lock()
	session, err := loadClientSession()
	clientConfigMu.Unlock()
	if err != nil || session == "" {
		return `{"ret":0,"error":"login-required"}`
	}
	req, err := http.NewRequest(http.MethodPost, target, bytes.NewReader(data))
	if err != nil {
		return failed
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", clientAPIUserAgent)
	req.Header.Set("Authorization", "Bearer "+session)
	response, err := clientHTTP().Do(req)
	if err != nil {
		return failed
	}
	defer response.Body.Close()
	if response.StatusCode == 401 {
		return `{"ret":0,"error":"login-required"}`
	}
	if response.StatusCode == 429 {
		return `{"ret":0,"error":"rate-limited"}`
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return failed
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 8193))
	if err != nil || len(body) > 8192 || !json.Valid(body) {
		return failed
	}
	return string(body)
}
