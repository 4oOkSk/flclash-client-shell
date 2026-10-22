package main

import (
	"encoding/json"
	"fmt"
	"runtime"
	"unsafe"
)

type MethodCall struct {
	ID        string          `json:"id,omitempty"`
	Method    CoreMethod      `json:"method"`
	Arguments json.RawMessage `json:"arguments"`
}

func (call MethodCall) decodeArguments(target any) error {
	if len(call.Arguments) == 0 || string(call.Arguments) == "null" {
		return fmt.Errorf("missing arguments")
	}
	return json.Unmarshal(call.Arguments, target)
}

func decodeMethodArguments(call *MethodCall, response MethodResponse, target any) bool {
	if err := call.decodeArguments(target); err != nil {
		response.failure(
			"invalid_arguments",
			fmt.Sprintf("invalid arguments for %s: %v", call.Method, err),
			nil,
		)
		return false
	}
	return true
}

type MethodError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details"`
}

type MethodResponse struct {
	ID       string       `json:"id,omitempty"`
	Result   any          `json:"result"`
	Error    *MethodError `json:"error,omitempty"`
	callback unsafe.Pointer
}

func (response MethodResponse) JSON() ([]byte, error) {
	return json.Marshal(response)
}

func (response MethodResponse) success(result any) {
	response.Result = result
	response.Error = nil
	response.send()
}

func (response MethodResponse) failure(code, message string, details any) {
	response.Result = nil
	response.Error = &MethodError{
		Code:    code,
		Message: message,
		Details: details,
	}
	response.send()
}

func (response MethodResponse) notImplemented(method CoreMethod) {
	response.failure(
		"not_implemented",
		fmt.Sprintf("unknown method: %s", method),
		nil,
	)
}

func handleMethodCall(call *MethodCall, response MethodResponse) {
	// The crash method is a developer-only fatal-path test. It must bypass the
	// recovery below so the core process terminates; on Android this also
	// terminates the in-process application.
	if call.Method == crashMethod {
		handleCrash()
		return
	}
	defer func() {
		if r := recover(); r != nil {
			buf := make([]byte, 4096)
			n := runtime.Stack(buf, false)
			logError("panic in handleMethodCall(%s): %v\n%s", call.Method, r, buf[:n])
			response.failure("internal_error", fmt.Sprintf("internal panic: %v", r), nil)
		}
	}()
	if handler, ok := coreMethodHandlers[call.Method]; ok {
		handler(call, response)
	} else if !handlePlatformMethodCall(call, response) {
		response.notImplemented(call.Method)
	}
}
