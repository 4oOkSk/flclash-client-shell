package log

import (
	"bytes"
	"strings"
	"testing"

	logrus "github.com/sirupsen/logrus"
)

func TestPayloadFilterPrecedesEventAndConsoleOutput(t *testing.T) {
	var output bytes.Buffer
	previousOutput := logrus.StandardLogger().Out
	logrus.SetOutput(&output)
	SetPayloadFilter(func(payload string) string {
		return strings.ReplaceAll(payload, "node.example.com:8443", "[server-endpoint]")
	})
	t.Cleanup(func() {
		SetPayloadFilter(nil)
		logrus.SetOutput(previousOutput)
	})
	event := newLog(WARNING, "dial %s: timeout", "node.example.com:8443")
	print(event)
	if event.Payload != "dial [server-endpoint]: timeout" || event.LogLevel != WARNING {
		t.Fatal("filtered event did not preserve diagnostic state")
	}
	if strings.Contains(output.String(), "node.example.com") || strings.Contains(output.String(), "8443") {
		t.Fatal("console output exposed a server endpoint")
	}
	SetPayloadFilter(nil)
	if newLog(INFO, "%s", "ordinary.example.com:443").Payload != "ordinary.example.com:443" {
		t.Fatal("unset filter changed generic logs")
	}
}
