package main

import (
	"bytes"
	"net/http"
)

// These defaults keep source builds functional. Private release builds may
// replace them in a generated, untracked build-config file.
var (
	clientAPIUserAgent       = "PrivateClient/1"
	clientLoginEndpointPath  = "/login"
	clientConfigEndpointPath = "/config"
	clientLogoutEndpointPath = "/logout"
)

func newClientAPIRequest(method, endpoint string, body []byte) (*http.Request, error) {
	req, err := http.NewRequest(method, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", clientAPIUserAgent)
	return req, nil
}
