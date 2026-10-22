package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"

	P "github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/resource"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	CP "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/listener"
	RP "github.com/metacubex/mihomo/rules/provider"
	T "github.com/metacubex/mihomo/tunnel"
)

func isolatedHardeningRuntime(t *testing.T) {
	t.Helper()
	home, previous, running := C.Path.HomeDir(), currentConfig, isRunning
	apply, initialized := applyRuntimeConfig, isInit.Load()
	names := append([]string(nil), config.GetProxyNameList()...)
	C.SetHomeDir(t.TempDir())
	isRunning = false
	applyRuntimeConfig = func(*config.Config) {}
	t.Cleanup(func() {
		handleStopListener()
		C.SetHomeDir(home)
		currentConfig, isRunning = previous, running
		applyRuntimeConfig = apply
		isInit.Store(initialized)
		config.SetProxyNameList(names)
	})
}

func TestProviderSideloadReportsErrorsAndPreservesFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "provider.yaml")
	if err := os.WriteFile(path, []byte("previous"), 0600); err != nil {
		t.Fatal(err)
	}
	parseErr := errors.New("invalid provider")
	hc := P.NewHealthCheck(nil, "", 100, 0, true, nil)
	p, err := P.NewProxySetProvider("test", 0, nil, func([]byte) ([]C.Proxy, error) {
		return nil, parseErr
	}, resource.NewFileVehicle(path), hc)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if err := sideUpdateExternalProvider(p, []byte("invalid")); !errors.Is(err, parseErr) {
		t.Fatalf("got %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "previous" {
		t.Fatalf("old file changed: %q %v", data, err)
	}
}

func TestRealRuleProviderCanBeSideloaded(t *testing.T) {
	RP.SetTunnel(T.Tunnel)
	p := RP.NewRuleSetProvider("test", CP.Domain, CP.YamlRule, 0,
		resource.NewFileVehicle(filepath.Join(t.TempDir(), "rules.yaml")), nil, nil, nil)
	defer p.(*RP.RuleSetProvider).Close()
	if err := sideUpdateExternalProvider(p, []byte("payload:\n  - example.com\n")); err != nil {
		t.Fatal(err)
	}
}

func TestValidationRejectsMissingEmptyAndSemanticallyInvalidFiles(t *testing.T) {
	isolatedHardeningRuntime(t)
	config.SetProxyNameList([]string{"previous"})
	path := filepath.Join(C.Path.HomeDir(), "validate.yaml")
	if result := handleValidateConfig(path); result == "" {
		t.Fatal("missing file accepted")
	}
	for _, content := range []string{"", "rules:\n  - DOMAIN,example.com,missing-proxy\n"} {
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
		if result := handleValidateConfig(path); result == "" {
			t.Fatal("invalid file accepted")
		}
	}
	if err := os.WriteFile(path, []byte("rules: [MATCH,DIRECT]"), 0600); err != nil {
		t.Fatal(err)
	}
	// A real valid validation must not publish candidate names either.
	if err := os.WriteFile(path, []byte("rules:\n  - MATCH,DIRECT\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if result := handleValidateConfig(path); result != "" {
		t.Fatal(result)
	}
	if names := config.GetProxyNameList(); len(names) != 1 || names[0] != "previous" {
		t.Fatalf("validation published names: %v", names)
	}
}

func TestFailedDiskConfigKeepsWorkingConfig(t *testing.T) {
	isolatedHardeningRuntime(t)
	path := filepath.Join(C.Path.HomeDir(), "config.yaml")
	if err := os.WriteFile(path, []byte("rules:\n  - MATCH,REJECT\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := applyConfig(defaultSetupParams()); err != nil {
		t.Fatal(err)
	}
	working := currentConfig
	if err := os.WriteFile(path, []byte("rules: [invalid]"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := applyConfig(defaultSetupParams()); err == nil || currentConfig != working {
		t.Fatalf("disk error=%v working changed=%v", err, currentConfig != working)
	}
}

func TestListenerBindFailureIsNotReady(t *testing.T) {
	isolatedHardeningRuntime(t)
	busy, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	raw := config.DefaultRawConfig()
	raw.MixedPort = busy.Addr().(*net.TCPAddr).Port
	raw.AllowLan, raw.Tun.Enable, raw.DNS.Enable = false, false, false
	currentConfig, err = config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	if handleStartListener() || isRunning || listener.GetPorts().MixedPort != 0 {
		t.Fatal("failed listener was marked ready")
	}
}

func TestRuntimeUpdateWithoutAppliedConfigFailsWithoutPanic(t *testing.T) {
	isolatedHardeningRuntime(t)
	currentConfig = nil
	isInit.Store(true)
	port := 17990
	if result := handleUpdateConfig(&UpdateParams{MixedPort: &port}); result != "config not applied" {
		t.Fatalf("unexpected result: %q", result)
	}
	if currentConfig != nil || isRunning || listener.GetPorts().MixedPort != 0 {
		t.Fatal("early runtime update started or invented a configuration")
	}
}

func TestFullApplyListenerFailureDoesNotPublishCandidate(t *testing.T) {
	isolatedHardeningRuntime(t)
	busy, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	raw := config.DefaultRawConfig()
	raw.MixedPort, raw.AllowLan, raw.Tun.Enable, raw.DNS.Enable = 0, false, false, false
	currentConfig, err = config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	working := currentConfig
	isRunning = true
	config.SetProxyNameList([]string{"previous"})
	runtimeCalls := 0
	applyRuntimeConfig = func(*config.Config) { runtimeCalls++ }
	content := fmt.Sprintf("mixed-port: %d\nallow-lan: false\ndns:\n  enable: false\ntun:\n  enable: false\nrules:\n  - MATCH,DIRECT\n", busy.Addr().(*net.TCPAddr).Port)
	if err := os.WriteFile(filepath.Join(C.Path.HomeDir(), "config.yaml"), []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	err = applyConfig(defaultSetupParams())
	if !errors.Is(err, errCoreListenersStopped) || currentConfig != working || isRunning || listener.GetPorts().MixedPort != 0 {
		t.Fatalf("error=%v current changed=%v running=%v ports=%+v", err, currentConfig != working, isRunning, listener.GetPorts())
	}
	if runtimeCalls != 0 {
		t.Fatal("failed candidate was published")
	}
	if names := config.GetProxyNameList(); len(names) != 1 || names[0] != "previous" {
		t.Fatal("candidate names were published")
	}
}

func TestRuntimeListenerFailureStopsPartialListeners(t *testing.T) {
	isolatedHardeningRuntime(t)
	busy, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	raw := config.DefaultRawConfig()
	raw.MixedPort = busy.Addr().(*net.TCPAddr).Port
	raw.AllowLan, raw.Tun.Enable, raw.DNS.Enable = false, false, false
	currentConfig, err = config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	isRunning = true
	if result := handleUpdateConfig(&UpdateParams{}); result == "" {
		t.Fatal("runtime listener failure was accepted")
	}
	if isRunning || listener.GetPorts().MixedPort != 0 {
		t.Fatal("failed runtime listener remained ready")
	}
}
