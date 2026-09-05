package core

import (
	"reflect"
	"testing"
)

func TestUDPMessagePackRoundTrip(test *testing.T) {
	message := udpMessage{
		SessionID: 123,
		Host:      "example.test",
		Port:      53,
		MsgID:     7,
		FragCount: 1,
		Data:      []byte("udp payload"),
	}
	packed := message.Pack()
	if len(packed) != message.Size() {
		test.Fatalf("packet length=%d want=%d", len(packed), message.Size())
	}
	var decoded udpMessage
	if err := decoded.Unpack(packed); err != nil {
		test.Fatal(err)
	}
	if !reflect.DeepEqual(decoded, message) {
		test.Fatal("UDP packet lost its header or payload during serialization")
	}
}
