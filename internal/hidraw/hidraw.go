// Package hidraw discovers and talks to HID devices through Linux /dev/hidraw nodes.
package hidraw

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Info describes one hidraw node.
type Info struct {
	Path      string // /dev/hidrawN
	Name      string // HID_NAME from uevent
	VendorID  uint16
	ProductID uint16
	Interface int    // USB bInterfaceNumber, -1 if unknown
	UsagePage uint16 // first usage page in the report descriptor
	Usage     uint16
}

// Enumerate lists all hidraw nodes with their identifiers.
func Enumerate() ([]Info, error) {
	nodes, err := filepath.Glob("/sys/class/hidraw/hidraw*")
	if err != nil {
		return nil, err
	}
	var out []Info
	for _, n := range nodes {
		info, err := readInfo(n)
		if err != nil {
			continue
		}
		out = append(out, info)
	}
	return out, nil
}

func readInfo(sysPath string) (Info, error) {
	info := Info{Path: "/dev/" + filepath.Base(sysPath), Interface: -1}
	uevent, err := os.ReadFile(filepath.Join(sysPath, "device", "uevent"))
	if err != nil {
		return info, err
	}
	for _, line := range strings.Split(string(uevent), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch k {
		case "HID_NAME":
			info.Name = v
		case "HID_ID": // bus:vendor:product, e.g. 0003:000005AC:0000024F
			parts := strings.Split(v, ":")
			if len(parts) == 3 {
				vid, _ := strconv.ParseUint(parts[1], 16, 32)
				pid, _ := strconv.ParseUint(parts[2], 16, 32)
				info.VendorID, info.ProductID = uint16(vid), uint16(pid)
			}
		}
	}
	// device -> .../1-4:1.3/0003:05AC:024F.0007; the parent holds bInterfaceNumber.
	if dev, err := filepath.EvalSymlinks(filepath.Join(sysPath, "device")); err == nil {
		if b, err := os.ReadFile(filepath.Join(filepath.Dir(dev), "bInterfaceNumber")); err == nil {
			if n, err := strconv.ParseUint(strings.TrimSpace(string(b)), 16, 8); err == nil {
				info.Interface = int(n)
			}
		}
	}
	if desc, err := os.ReadFile(filepath.Join(sysPath, "device", "report_descriptor")); err == nil {
		info.UsagePage, info.Usage = firstUsage(desc)
	}
	return info, nil
}

// firstUsage returns the first Usage Page and Usage items of a report descriptor.
func firstUsage(d []byte) (page, usage uint16) {
	var gotPage, gotUsage bool
	for i := 0; i < len(d) && !(gotPage && gotUsage); {
		prefix := d[i]
		size := int(prefix & 0x03)
		if size == 3 {
			size = 4
		}
		if i+1+size > len(d) {
			break
		}
		var val uint32
		for j := 0; j < size; j++ {
			val |= uint32(d[i+1+j]) << (8 * j)
		}
		switch prefix & 0xFC {
		case 0x04: // Usage Page (global)
			if !gotPage {
				page, gotPage = uint16(val), true
			}
		case 0x08: // Usage (local)
			if !gotUsage {
				usage, gotUsage = uint16(val), true
			}
		}
		i += 1 + size
	}
	return page, usage
}

// Device is an open hidraw node.
type Device struct {
	f *os.File
}

// Open opens a hidraw node for reading and writing.
func Open(path string) (*Device, error) {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	return &Device{f: f}, nil
}

func (d *Device) Close() error { return d.f.Close() }

// Write sends an output report. For devices without report IDs, the first byte
// must be 0x00 followed by the report payload.
func (d *Device) Write(report []byte) (int, error) { return d.f.Write(report) }

// SetFeature sends a feature report. For devices without report IDs, the first
// byte must be 0x00 followed by the report payload.
func (d *Device) SetFeature(report []byte) error {
	return d.ioctl(0x06, report) // HIDIOCSFEATURE(len)
}

// GetFeature reads a feature report into report. report[0] selects the report
// ID (0x00 when the device has none) and is overwritten with the reply.
func (d *Device) GetFeature(report []byte) error {
	return d.ioctl(0x07, report) // HIDIOCGFEATURE(len)
}

func (d *Device) ioctl(nr uintptr, buf []byte) error {
	if len(buf) == 0 {
		return errors.New("hidraw: empty feature report")
	}
	// _IOC(_IOC_READ|_IOC_WRITE, 'H', nr, len)
	req := uintptr(3)<<30 | uintptr(len(buf))<<16 | uintptr('H')<<8 | nr
	for {
		_, _, errno := unix.Syscall(unix.SYS_IOCTL, d.f.Fd(), req, uintptr(unsafe.Pointer(&buf[0])))
		if errno == unix.EINTR {
			continue
		}
		if errno != 0 {
			return fmt.Errorf("hidraw feature ioctl: %w", errno)
		}
		return nil
	}
}

// ErrTimeout is returned by Read when no report arrives in time.
var ErrTimeout = errors.New("hidraw: read timeout")

// Read waits up to timeout for one input report.
func (d *Device) Read(buf []byte, timeout time.Duration) (int, error) {
	fds := []unix.PollFd{{Fd: int32(d.f.Fd()), Events: unix.POLLIN}}
	for {
		n, err := unix.Poll(fds, int(timeout.Milliseconds()))
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return 0, fmt.Errorf("hidraw poll: %w", err)
		}
		if n == 0 {
			return 0, ErrTimeout
		}
		return d.f.Read(buf)
	}
}
