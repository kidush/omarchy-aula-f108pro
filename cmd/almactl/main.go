// Command almactl configures the Alma F108 Pro keyboard on Linux.
package main

import (
	"context"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"sync"
	"time"

	"github.com/kidush/omarchy-aula-f108pro/internal/aula"
	"github.com/kidush/omarchy-aula-f108pro/internal/hidraw"
)

const (
	vendorID        = 0x05AC // spoofed Apple ID used by the F108 Pro dongle
	productID       = 0x024F
	vendorUsagePage = 0xFF60

	wiredVendorID  = 0x0C45 // Sonix, keyboard on its USB cable
	wiredProductID = 0x800A
	wiredUsagePage = 0xFF13 // 64-byte feature reports, interface 3
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "list":
		err = cmdList()
	case "listen":
		err = cmdListen()
	case "info":
		err = cmdInfo()
	case "sync-time":
		err = cmdSyncTime()
	case "light":
		err = cmdLight(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "almactl:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage: almactl <command>

commands:
  list       show the keyboard's HID interfaces
  listen     print reports arriving on the vendor channels (read-only)
  info       show the connection (usb or 2.4g) and, over 2.4g, battery level
  sync-time  set the keyboard clock to the system time
  light      set the backlight: light [-b 0-5] [-s 0-5] [-rainbow] <mode> [RRGGBB]
             modes: off, static, breath, spectrum, rolling`)
}

func keyboardNodes() ([]hidraw.Info, error) {
	all, err := hidraw.Enumerate()
	if err != nil {
		return nil, err
	}
	var out []hidraw.Info
	for _, i := range all {
		if (i.VendorID == vendorID && i.ProductID == productID) ||
			(i.VendorID == wiredVendorID && i.ProductID == wiredProductID) {
			out = append(out, i)
		}
	}
	if len(out) == 0 {
		return nil, errors.New("keyboard not found (is the dongle or cable plugged in?)")
	}
	return out, nil
}

func cmdList() error {
	nodes, err := keyboardNodes()
	if err != nil {
		return err
	}
	for _, n := range nodes {
		fmt.Printf("%-14s iface=%d usage=%04x:%04x  %s\n", n.Path, n.Interface, n.UsagePage, n.Usage, n.Name)
	}
	return nil
}

func cmdListen() error {
	nodes, err := keyboardNodes()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	var wg sync.WaitGroup
	for _, n := range nodes {
		if n.UsagePage != vendorUsagePage {
			continue
		}
		dev, err := hidraw.Open(n.Path)
		if err != nil {
			return fmt.Errorf("open %s: %w", n.Path, err)
		}
		defer dev.Close()
		wg.Add(1)
		go func(path string) {
			defer wg.Done()
			buf := make([]byte, 64)
			for ctx.Err() == nil {
				k, err := dev.Read(buf, 200*time.Millisecond)
				if errors.Is(err, hidraw.ErrTimeout) {
					continue
				}
				if err != nil {
					fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
					return
				}
				fmt.Printf("%s %s % x\n", time.Now().Format("15:04:05.000"), path, buf[:k])
			}
		}(n.Path)
		fmt.Fprintf(os.Stderr, "listening on %s (iface %d)\n", n.Path, n.Interface)
	}
	wg.Wait()
	return nil
}

// openDongle opens the 32-byte vendor channel (interface 3) used for configuration.
func openDongle() (*aula.Conn, error) {
	nodes, err := keyboardNodes()
	if err != nil {
		return nil, err
	}
	for _, n := range nodes {
		if n.VendorID == vendorID && n.UsagePage == vendorUsagePage && n.Interface == 3 {
			return aula.Open(n.Path)
		}
	}
	return nil, errors.New("vendor channel (interface 3, usage page ff60) not found")
}

// wiredNode returns the config interface of a keyboard on its USB cable, if any.
func wiredNode() (hidraw.Info, bool) {
	nodes, err := keyboardNodes()
	if err != nil {
		return hidraw.Info{}, false
	}
	for _, n := range nodes {
		if n.VendorID == wiredVendorID && n.UsagePage == wiredUsagePage {
			return n, true
		}
	}
	return hidraw.Info{}, false
}

// configurator is what both transports can set.
type configurator interface {
	SetLight(aula.Light) error
	SyncClock(time.Time) error
	Close() error
}

// openKeyboard prefers the cable: when it is plugged in, the keyboard is
// configured over USB even if the dongle is also connected.
func openKeyboard() (configurator, error) {
	if n, ok := wiredNode(); ok {
		return aula.OpenWired(n.Path)
	}
	return openDongle()
}

func cmdInfo() error {
	if _, ok := wiredNode(); ok {
		// The wired protocol has no battery or status query.
		fmt.Println("connection usb")
		return nil
	}
	c, err := openDongle()
	if err != nil {
		return err
	}
	defer c.Close()
	status, err := c.Probe()
	if err != nil {
		return err
	}
	battery, err := c.Battery()
	if err != nil {
		return err
	}
	fmt.Println("connection 2.4g")
	fmt.Printf("battery  %d%%\n", battery)
	fmt.Printf("status   % x\n", status[3:31])
	return nil
}

func cmdSyncTime() error {
	c, err := openKeyboard()
	if err != nil {
		return err
	}
	defer c.Close()
	now := time.Now()
	if err := c.SyncClock(now); err != nil {
		return err
	}
	fmt.Println("clock set to", now.Format("2006-01-02 15:04:05 Mon"))
	return nil
}

var lightModes = map[string]byte{
	"off":      aula.ModeOff,
	"static":   aula.ModeStatic,
	"breath":   aula.ModeBreath,
	"spectrum": aula.ModeSpectrum,
	"rolling":  aula.ModeRolling,
}

func cmdLight(args []string) error {
	fs := flag.NewFlagSet("light", flag.ContinueOnError)
	brightness := fs.Uint("b", aula.MaxLevel, "brightness 0-5")
	speed := fs.Uint("s", 3, "effect speed 0-5")
	rainbow := fs.Bool("rainbow", false, "cycle colors instead of the single color")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return errors.New("usage: almactl light [-b 0-5] [-s 0-5] [-rainbow] <mode> [RRGGBB]")
	}
	mode, ok := lightModes[fs.Arg(0)]
	if !ok {
		return fmt.Errorf("unknown mode %q", fs.Arg(0))
	}
	if *brightness > aula.MaxLevel || *speed > aula.MaxLevel {
		return fmt.Errorf("brightness and speed go from 0 to %d", aula.MaxLevel)
	}
	light := aula.Light{Mode: mode, Colorful: *rainbow, Brightness: byte(*brightness), Speed: byte(*speed)}
	if fs.NArg() > 1 {
		rgb, err := hex.DecodeString(strings.TrimPrefix(fs.Arg(1), "#"))
		if err != nil || len(rgb) != 3 {
			return fmt.Errorf("invalid color %q, want RRGGBB", fs.Arg(1))
		}
		light.R, light.G, light.B = rgb[0], rgb[1], rgb[2]
	}

	c, err := openKeyboard()
	if err != nil {
		return err
	}
	defer c.Close()
	return c.SetLight(light)
}
