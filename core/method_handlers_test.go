//go:build !cgo

package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

type methodResponseBuffer struct{ bytes.Buffer }

func (*methodResponseBuffer) Close() error { return nil }

func captureMethodResponse(test *testing.T, invoke func(MethodResponse)) MethodResponse {
	test.Helper()
	previous := conn
	buffer := &methodResponseBuffer{}
	conn = buffer
	defer func() { conn = previous }()
	invoke(MethodResponse{ID: "request"})
	payload, err := readFrame(buffer)
	if err != nil {
		test.Fatal(err)
	}
	var response MethodResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		test.Fatal(err)
	}
	if response.ID != "request" || buffer.Len() != 0 {
		test.Fatalf("unexpected response identity or duplicate frame: %+v", response)
	}
	return response
}

func TestMethodAdapters(test *testing.T) {
	for _, scenario := range []struct {
		name      string
		handler   methodHandler
		arguments string
		want      any
	}{
		{"value", argumentMethod(func(value string) string { return value }), `"input"`, "input"},
		{"pointer", pointerMethod(func(value *InitParams) string { return value.HomeDir }), `{"home-dir":"example"}`, "example"},
		{"callback", callbackMethod(func(value string, reply func(string)) { reply(value) }), `"callback"`, "callback"},
		{"result", resultMethod(func() string { return "result" }), `null`, "result"},
		{"action", actionMethod(func() {}), `null`, true},
	} {
		test.Run(scenario.name, func(test *testing.T) {
			response := captureMethodResponse(test, func(response MethodResponse) {
				scenario.handler(&MethodCall{Arguments: json.RawMessage(scenario.arguments)}, response)
			})
			if response.Error != nil || response.Result != scenario.want {
				test.Fatalf("response = %+v, want %v", response, scenario.want)
			}
		})
	}
}

func TestMethodArgumentFailuresDoNotInvokeHandler(test *testing.T) {
	for _, arguments := range []string{"", "null", "{", "true", `"string"`} {
		test.Run(arguments, func(test *testing.T) {
			response := captureMethodResponse(test, func(response MethodResponse) {
				handler := pointerMethod(func(*InitParams) bool {
					test.Fatal("invalid arguments reached handler")
					return false
				})
				handler(&MethodCall{Method: initClashMethod, Arguments: json.RawMessage(arguments)}, response)
			})
			if response.Error == nil || response.Error.Code != "invalid_arguments" {
				test.Fatalf("response = %+v", response)
			}
		})
	}
}

func TestMethodDispatchUnknownAndPanic(test *testing.T) {
	method := CoreMethod("test-panic")
	coreMethodHandlers[method] = resultMethod(func() bool { panic("test panic") })
	defer delete(coreMethodHandlers, method)
	for name, code := range map[CoreMethod]string{method: "internal_error", "unknown": "not_implemented"} {
		response := captureMethodResponse(test, func(response MethodResponse) {
			handleMethodCall(&MethodCall{Method: name}, response)
		})
		if response.Error == nil || response.Error.Code != code {
			test.Fatalf("method %s response = %+v, want %s", name, response, code)
		}
	}
}
