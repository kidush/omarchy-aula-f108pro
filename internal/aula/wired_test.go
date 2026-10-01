package aula

import (
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

// Layouts from the decompiled vendor senders (docs/protocol.md section 7).

func TestWiredLightTransactionMatchesVendorDriver(t *testing.T) {
	steps := wiredLightSteps(Light{Mode: ModeStatic, R: 0xFF, Brightness: 5, Speed: 3})
	want := []struct {
		hex      string
		readback bool
	}{
		{"0418", true},                                  // begin
		{"0413000000000000 01", true},                   // init, one data report
		{"01ff0000 00000000 00050300 0000 aa55", false}, // FUN_0042b040: AA 55 at 14-15
		{"0402", true},                                  // apply
		{"04f0", false},                                 // finalize
	}
	checkSteps(t, steps, want)
}

func TestWiredClockTransactionMatchesVendorDriver(t *testing.T) {
	tm := time.Date(2026, 9, 29, 14, 30, 5, 0, time.Local) // Tuesday
	steps := wiredClockSteps(tm)
	data := "00015a1a091d0e1e05 0002" + strings.Repeat("00", 51) + "aa55" // FUN_00423b10: AA 55 at 62-63
	want := []struct {
		hex      string
		readback bool
	}{
		{"0418", true},
		{"0428000000000000 01", true},
		{data, true},
		{"0402", true}, // no finalize for the clock
	}
	checkSteps(t, steps, want)
}

func checkSteps(t *testing.T, got []wiredStep, want []struct {
	hex      string
	readback bool
}) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %d reports, want %d", len(got), len(want))
	}
	for i, w := range want {
		var r WiredReport
		b, err := hex.DecodeString(stripSpaces(w.hex))
		if err != nil {
			t.Fatal(err)
		}
		copy(r[:], b) // zero-padded to 64 bytes
		if got[i].report != r {
			t.Errorf("report %d\n got %x\nwant %x", i, got[i].report, r)
		}
		if got[i].readback != w.readback {
			t.Errorf("report %d readback = %v, want %v", i, got[i].readback, w.readback)
		}
	}
}
