package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestScriptTransformsIsolatedConfiguration(t *testing.T) {
	input := json.RawMessage(`{"rules":[]}`)
	value, err := evaluateScript(&ScriptParams{
		Script: `function main(c) { c.rules.push("MATCH,REJECT"); return c; }`, Config: input,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(value, []byte("MATCH,REJECT")) || string(input) != `{"rules":[]}` {
		t.Fatalf("value=%s input=%s", value, input)
	}
}

func TestScriptInterruptsLoopAndAcceptsNextInvocation(t *testing.T) {
	start := time.Now()
	_, err := evaluateScript(&ScriptParams{Script: `function main(c) { while (true) {} }`, Config: json.RawMessage(`{}`)})
	if err == nil || !strings.Contains(err.Error(), "time limit") {
		t.Fatalf("err=%v", err)
	}
	if time.Since(start) > 8*time.Second {
		t.Fatal("interrupt was not bounded")
	}
	for i := 0; i < 100; i++ {
		if _, err := evaluateScript(&ScriptParams{Script: `function main(c) { return c; }`, Config: json.RawMessage(`{}`)}); err != nil {
			t.Fatal(err)
		}
	}
}

func TestScriptRejectsInvalidAsyncAndHostAccess(t *testing.T) {
	for _, script := range []string{
		`function main(c) { return null; }`, `async function main(c) { return c; }`,
		`function main(c) { return fetch("http://example.com"); }`,
		`function main(c) { return require("fs"); }`,
		`function main(c) { return main(c); }`,
	} {
		if _, err := evaluateScript(&ScriptParams{Script: script, Config: json.RawMessage(`{}`)}); err == nil {
			t.Fatalf("accepted %s", script)
		}
	}
}
