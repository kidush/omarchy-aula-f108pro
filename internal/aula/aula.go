// Package aula implements the AULA F108 Pro 2.4G dongle configuration protocol,
// which the Alma F108 Pro speaks. See docs/protocol.md.
package aula

import (
	"errors"
	"fmt"
	"time"

	"github.com/kidush/omarchy-aula-f108pro/internal/hidraw"
)

// ReportSize is the dongle's vendor output/input report size (no report ID).
const ReportSize = 32

// Opcodes (byte 0 of a packet).
const (
	CmdProbe     = 0x02
	CmdLight     = 0x05
	CmdClockSync = 0x0C
	CmdBattery   = 0x20
)

// Backlight effect ids for Light.Mode (docs/protocol.md 5.4).
const (
	ModeOff      = 0
	ModeStatic   = 1
	ModeBreath   = 7
	ModeSpectrum = 8
	ModeRolling  = 11 // factory default
)

// MaxLevel is the top value for Light.Brightness and Light.Speed.
const MaxLevel = 5

const (
	readWindow = 250 * time.Millisecond // the vendor driver polls 20 x (5 ms read + 10 ms sleep)
	retries    = 2
)

// ErrNoReply means the dongle dropped the command, which happens while the keyboard sleeps.
var ErrNoReply = errors.New("aula: no reply from keyboard (asleep? press a key to wake it)")

// Conn is a session on the dongle's 32-byte vendor channel.
type Conn struct {
	dev *hidraw.Device
}

// Open opens the vendor channel at path.
func Open(path string) (*Conn, error) {
	dev, err := hidraw.Open(path)
	if err != nil {
		return nil, err
	}
	return &Conn{dev: dev}, nil
}

func (c *Conn) Close() error { return c.dev.Close() }

// Packet is one 32-byte report: cmd, sub, index, 28 data bytes, checksum.
type Packet [ReportSize]byte

// NewPacket builds a packet with header bytes and data starting at offset 3.
func NewPacket(cmd, sub, index byte, data ...byte) Packet {
	var p Packet
	p[0], p[1], p[2] = cmd, sub, index
	copy(p[3:ReportSize-1], data)
	return p
}

func (p *Packet) seal() {
	var sum byte
	for _, b := range p[:ReportSize-1] {
		sum += b
	}
	p[ReportSize-1] = sum
}

// Exchange sends p and returns the dongle's reply, which echoes bytes 0-2.
func (c *Conn) Exchange(p Packet) (Packet, error) {
	p.seal()
	out := append([]byte{0}, p[:]...) // leading 0 = no report ID
	buf := make([]byte, 64)
	for try := 0; try <= retries; try++ {
		if _, err := c.dev.Write(out); err != nil {
			return Packet{}, fmt.Errorf("aula write: %w", err)
		}
		deadline := time.Now().Add(readWindow)
		for left := readWindow; left > 0; left = time.Until(deadline) {
			n, err := c.dev.Read(buf, left)
			if errors.Is(err, hidraw.ErrTimeout) {
				break
			}
			if err != nil {
				return Packet{}, fmt.Errorf("aula read: %w", err)
			}
			if n >= ReportSize && buf[0] == p[0] && buf[1] == p[1] && buf[2] == p[2] {
				var r Packet
				copy(r[:], buf)
				return r, nil
			}
			// Anything else is a stale reply or a notification; keep reading.
		}
	}
	return Packet{}, ErrNoReply
}

// Probe checks the keyboard is online and returns the raw status reply.
func (c *Conn) Probe() (Packet, error) {
	return c.Exchange(NewPacket(CmdProbe, 0, 0))
}

// Battery returns the battery level in percent.
func (c *Conn) Battery() (int, error) {
	r, err := c.Exchange(NewPacket(CmdBattery, 0x01, 0))
	if err != nil {
		return 0, err
	}
	return int(min(r[3], 100)), nil
}

// SyncClock sets the keyboard clock shown on the screen.
func (c *Conn) SyncClock(t time.Time) error {
	_, err := c.Exchange(clockPacket(t))
	return err
}

// Light is the main backlight setting.
type Light struct {
	Mode       byte
	R, G, B    byte
	Colorful   bool // rainbow instead of the single color
	Brightness byte // 0-MaxLevel
	Speed      byte // 0-MaxLevel
	Direction  byte
}

// SetLight applies the main backlight. The keyboard keeps it across power cycles.
func (c *Conn) SetLight(l Light) error {
	_, err := c.Exchange(lightPacket(l))
	return err
}

func lightPacket(l Light) Packet {
	if l.Mode == ModeOff {
		// The vendor driver leaves every field after the mode zeroed for "off".
		return NewPacket(CmdLight, 0x10, 0, ModeOff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xAA, 0x55)
	}
	var colorful byte
	if l.Colorful {
		colorful = 1
	}
	return NewPacket(CmdLight, 0x10, 0,
		l.Mode, l.R, l.G, l.B,
		0x00, 0x00, 0x00, 0x00,
		colorful, min(l.Brightness, MaxLevel), min(l.Speed, MaxLevel), l.Direction,
		0x00, 0x00,
		0xAA, 0x55,
	)
}

func clockPacket(t time.Time) Packet {
	return NewPacket(CmdClockSync, 0x10, 0,
		0x00, 0x01, 0x5A,
		byte(t.Year()%100), byte(t.Month()), byte(t.Day()),
		byte(t.Hour()), byte(t.Minute()), byte(t.Second()),
		0x00, byte(t.Weekday()),
		0x00, 0x00, 0x00,
		0xAA, 0x55,
	)
}
