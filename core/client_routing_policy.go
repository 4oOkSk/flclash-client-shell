package main

import (
	_ "embed"
	"encoding/json"
	"strings"
)

//go:embed routing_policy.json
var clientRoutingPolicyJSON []byte

type clientRoutingPolicyData struct {
	Version          int      `json:"version"`
	Revision         string   `json:"revision"`
	Priority         []string `json:"priority"`
	GoogleSites      []string `json:"googleSites"`
	ReturnSites      []string `json:"returnSites"`
	MainlandDNS      string   `json:"mainlandDns"`
	OverseasDNS      string   `json:"overseasDns"`
	MainlandDNSSites []string `json:"mainlandDnsSites"`
	MainlandDNSIP    []string `json:"mainlandDnsIp"`
}

func loadClientRoutingPolicy() clientRoutingPolicyData {
	var policy clientRoutingPolicyData
	decoder := json.NewDecoder(strings.NewReader(string(clientRoutingPolicyJSON)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&policy); err != nil {
		panic("invalid embedded routing policy: " + err.Error())
	}
	if policy.Version != 1 || strings.Join(policy.Priority, ",") != "private,google,return-supplement,mainland-dns,mainland,default" {
		panic("unsupported embedded routing policy")
	}
	return policy
}

var clientRoutingPolicy = loadClientRoutingPolicy()
var clientReturnGeoSites = clientRoutingPolicy.ReturnSites
var clientMainlandDNS = clientRoutingPolicy.MainlandDNS
var clientOtherDNS = clientRoutingPolicy.OverseasDNS
