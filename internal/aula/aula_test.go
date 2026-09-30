package aula

import (
	"encoding/hex"
	"testing"
	"time"
)

func TestClockPacketMatchesVendorDriver(t *testing.T) {
	// Example from docs/protocol.md 5.3: 2026-09-29 14:30:05, Tuesday.
	want := "0c10000001 5a1a091d0e1e05 0002 000000 aa55 000000000000000000000000 e9"
	tm := time.Date(2026, 9, 29, 14, 30, 5, 0, time.Local)
	p := clockPacket(tm)
	p.seal()
	if got := hex.EncodeToString(p[:]); got != stripSpaces(want) {
		t.Fatalf("clock packet\n got %s\nwant %s", got, stripSpaces(want))
	}
}

func TestLightPacketMatchesVendorDriver(t *testing.T) {
	// Example from docs/protocol.md 5.4: static red, brightness 5, speed 3.
	want := "051000 01ff0000 00000000 00050300 0000 aa55 000000000000000000000000 1c"
	p := lightPacket(Light{Mode: ModeStatic, R: 0xFF, Brightness: 5, Speed: 3})
	p.seal()
	if got := hex.EncodeToString(p[:]); got != stripSpaces(want) {
		t.Fatalf("light packet\n got %s\nwant %s", got, stripSpaces(want))
	}
}

func TestLightOffLeavesFieldsZero(t *testing.T) {
	p := lightPacket(Light{Mode: ModeOff, R: 0xFF, Brightness: 5, Speed: 3})
	for i := 4; i <= 14; i++ {
		if p[i] != 0 {
			t.Fatalf("byte %d = %#x, want 0 for mode off", i, p[i])
		}
	}
}

func TestChecksumMatchesCapturedReply(t *testing.T) {
	// Battery reply captured from the real keyboard: 20 01 00 56 ... 77.
	p := NewPacket(CmdBattery, 0x01, 0x00, 0x56)
	p.seal()
	if p[31] != 0x77 {
		t.Fatalf("checksum = %#x, want 0x77", p[31])
	}
}

func stripSpaces(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != ' ' {
			out = append(out, s[i])
		}
	}
	return string(out)
}
