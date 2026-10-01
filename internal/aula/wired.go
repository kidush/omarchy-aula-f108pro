package aula

import (
	"fmt"
	"time"

	"github.com/kidush/omarchy-aula-f108pro/internal/hidraw"
)

// WiredReportSize is the feature report size on the wired config interface
// (interface 3, usage page 0xFF13, no report ID).
const WiredReportSize = 64

// The vendor driver sleeps cmd_delaytime (35 ms) before every feature report
// and before each readback (docs/protocol.md section 7).
const wiredDelay = 35 * time.Millisecond

// Wired transaction opcodes (byte 1 after the 0x04 prefix).
const (
	wiredBegin    = 0x18
	wiredApply    = 0x02
	wiredFinalize = 0xF0
	wiredLight    = 0x13
	wiredClock    = 0x28
)

// WiredReport is one 64-byte feature report payload.
type WiredReport [WiredReportSize]byte

// Wired is a session on the keyboard's USB config interface (0C45:800A).
type Wired struct {
	dev *hidraw.Device
}

// OpenWired opens the wired config channel at path.
func OpenWired(path string) (*Wired, error) {
	dev, err := hidraw.Open(path)
	if err != nil {
		return nil, err
	}
	return &Wired{dev: dev}, nil
}

func (w *Wired) Close() error { return w.dev.Close() }

// send writes one feature report and, like the vendor driver, optionally
// reads it back. The readback content is not checked by the driver either.
func (w *Wired) send(r WiredReport, readback bool) error {
	buf := append([]byte{0}, r[:]...) // leading 0 = no report ID
	time.Sleep(wiredDelay)
	if err := w.dev.SetFeature(buf); err != nil {
		return fmt.Errorf("aula wired set feature %02x %02x: %w", r[0], r[1], err)
	}
	if !readback {
		return nil
	}
	time.Sleep(wiredDelay)
	if err := w.dev.GetFeature(buf); err != nil {
		return fmt.Errorf("aula wired get feature %02x %02x: %w", r[0], r[1], err)
	}
	return nil
}

func (w *Wired) sendAll(steps []wiredStep) error {
	for _, s := range steps {
		if err := w.send(s.report, s.readback); err != nil {
			return err
		}
	}
	return nil
}

type wiredStep struct {
	report   WiredReport
	readback bool
}

// SetLight applies the main backlight (vendor FUN_0042b040).
func (w *Wired) SetLight(l Light) error {
	return w.sendAll(wiredLightSteps(l))
}

// SyncClock sets the keyboard clock shown on the screen (vendor FUN_00423b10).
func (w *Wired) SyncClock(t time.Time) error {
	return w.sendAll(wiredClockSteps(t))
}

func wiredLightSteps(l Light) []wiredStep {
	var data WiredReport
	copy(data[:], lightBlock(l))
	return []wiredStep{
		{wiredControl(wiredBegin, 0), true},
		{wiredControl(wiredLight, 1), true},
		{data, false},
		{wiredControl(wiredApply, 0), true},
		{wiredControl(wiredFinalize, 0), false},
	}
}

func wiredClockSteps(t time.Time) []wiredStep {
	var data WiredReport
	copy(data[:], clockFields(t))
	data[62], data[63] = 0xAA, 0x55
	// The clock transaction has no finalize packet.
	return []wiredStep{
		{wiredControl(wiredBegin, 0), true},
		{wiredControl(wiredClock, 1), true},
		{data, true},
		{wiredControl(wiredApply, 0), true},
	}
}

// wiredControl builds a 04 <op> control report; byte 8 carries the number of
// data reports that follow an init packet.
func wiredControl(op, count byte) WiredReport {
	var r WiredReport
	r[0], r[1], r[8] = 0x04, op, count
	return r
}
