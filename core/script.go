package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/dop251/goja"
	"github.com/dop251/goja/parser"
)

const scriptTimeLimit = 2 * time.Second
const maxScriptConfigSize = 16 * 1024 * 1024

var scriptSlot = make(chan struct{}, 1)
var errScriptInterrupted = errors.New("script execution time limit exceeded")

// Each invocation owns a fresh VM. It exposes no filesystem/network/timers or
// Go host objects, and keeps execution off Flutter's UI isolate on every OS.
func evaluateScript(params *ScriptParams) (json.RawMessage, error) {
	if len(params.Script) > 1024*1024 || len(params.Config) > maxScriptConfigSize {
		return nil, errors.New("script input exceeds its limit")
	}
	var input map[string]any
	if err := json.Unmarshal(params.Config, &input); err != nil || input == nil {
		return nil, errors.New("script configuration must be an object")
	}
	if input["proxy-providers"] == nil {
		input["proxy-providers"] = map[string]any{}
	}
	config, err := json.Marshal(input)
	if err != nil {
		return nil, err
	}
	deadline := time.NewTimer(scriptTimeLimit)
	defer deadline.Stop()
	select {
	case scriptSlot <- struct{}{}:
		defer func() { <-scriptSlot }()
	case <-deadline.C:
		return nil, errors.New("script executor is busy")
	}
	vm := goja.New()
	vm.SetMaxCallStackSize(256)
	vm.SetParserOptions(parser.WithDisableSourceMaps)
	timer := time.AfterFunc(scriptTimeLimit, func() { vm.Interrupt(errScriptInterrupted) })
	defer timer.Stop()
	value, err := vm.RunString(fmt.Sprintf(`(function() {
		const stringify = JSON.stringify;
		const console = {log: function(){}, warn: function(){}, error: function(){}};
		%s
		const output = main(%s);
		if (!output || typeof output !== 'object' || Array.isArray(output) || typeof output.then === 'function') {
			throw new Error('Script must return a configuration object');
		}
		const encoded = stringify(output);
		if (typeof encoded !== 'string' || encoded.length > %d) {
			throw new Error('Script output exceeds its limit');
		}
		return encoded;
	})()`, params.Script, config, maxScriptConfigSize))
	if err != nil {
		var interrupted *goja.InterruptedError
		if errors.As(err, &interrupted) {
			return nil, errScriptInterrupted
		}
		// Do not return the script or server configuration in IPC diagnostics.
		return nil, errors.New("script is invalid or did not return a configuration object")
	}
	encoded, ok := value.Export().(string)
	if !ok || len(encoded) > maxScriptConfigSize {
		return nil, errors.New("invalid script result")
	}
	var output map[string]json.RawMessage
	if err := json.Unmarshal([]byte(encoded), &output); err != nil || output == nil {
		return nil, errors.New("script must return a configuration object")
	}
	return json.RawMessage(encoded), nil
}
