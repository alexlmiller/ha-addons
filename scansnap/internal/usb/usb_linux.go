package usb

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"
	"unsafe"
)

type usbdevfsBulkTransfer struct {
	Ep      uint32
	Len     uint32
	Timeout uint32
	Pad     [4]byte
	Data    *byte
}

const (
	usbdevfsBulk             = 0xc0185502
	usbdevfsClaimInterface   = 0x8004550f
	usbdevfsReleaseInterface = 0x80045510
	usbdevfsClearHalt        = 0x80045515
	usbdevfsReset            = 0x5514
)

const usbDevicesRoot = "/sys/bus/usb/devices"

const (
	product      = "132b"
	vendor       = "04c5"
	deviceToHost = 129
	hostToDevice = 2
)

type Device struct {
	name    string
	devName string
	f       *os.File
}

func newDevice(name string) (*Device, error) {
	dev := &Device{name: name}

	uevent, err := os.ReadFile(dev.sysPath("uevent"))
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(string(uevent), "\n") {
		if strings.HasPrefix(line, "DEVNAME=") {
			dev.devName = strings.TrimPrefix(line, "DEVNAME=")
		}
	}
	if dev.devName == "" {
		return nil, fmt.Errorf("%q did not contain a DEVNAME entry", dev.sysPath("uevent"))
	}

	dev.f, err = os.OpenFile(filepath.Join("/dev", dev.devName), os.O_RDWR, 0o664)
	if err != nil {
		return nil, err
	}

	var interfaceNumber uint32
	if _, _, errno := syscall.Syscall(
		syscall.SYS_IOCTL,
		dev.f.Fd(),
		usbdevfsClaimInterface,
		uintptr(unsafe.Pointer(&interfaceNumber)),
	); errno != 0 {
		_ = dev.f.Close()
		return nil, errno
	}

	return dev, nil
}

func (u *Device) sysPath(filename string) string {
	return filepath.Join(usbDevicesRoot, u.name, filename)
}

func (u *Device) Read(p []byte) (int, error) {
	bulk := usbdevfsBulkTransfer{
		Ep:      deviceToHost,
		Len:     uint32(len(p)),
		Timeout: uint32((3 * time.Second) / time.Millisecond),
		Data:    &p[0],
	}
	if _, _, errno := syscall.Syscall(
		syscall.SYS_IOCTL,
		u.f.Fd(),
		usbdevfsBulk,
		uintptr(unsafe.Pointer(&bulk)),
	); errno != 0 {
		return 0, errno
	}
	return int(bulk.Len), nil
}

func (u *Device) Write(p []byte) (int, error) {
	bulk := usbdevfsBulkTransfer{
		Ep:      hostToDevice,
		Len:     uint32(len(p)),
		Timeout: uint32((3 * time.Second) / time.Millisecond),
		Data:    &p[0],
	}
	if _, _, errno := syscall.Syscall(
		syscall.SYS_IOCTL,
		u.f.Fd(),
		usbdevfsBulk,
		uintptr(unsafe.Pointer(&bulk)),
	); errno != 0 {
		return 0, errno
	}
	return len(p), nil
}

func (u *Device) Close() error {
	var interfaceNumber uint32
	if _, _, errno := syscall.Syscall(
		syscall.SYS_IOCTL,
		u.f.Fd(),
		usbdevfsReleaseInterface,
		uintptr(unsafe.Pointer(&interfaceNumber)),
	); errno != 0 {
		return errno
	}
	return u.f.Close()
}

// CloseAfterReset closes the usbfs descriptor without releasing its interface.
// USBDEVFS_RESET rebinds the device interfaces, so a release against the old
// interface would only produce an expected ENODEV/EINVAL warning.
func (u *Device) CloseAfterReset() error {
	return u.f.Close()
}

// Recover clears a stalled bulk endpoint and resets its data toggle. The
// scanner can leave either endpoint stalled after an interrupted image
// transfer; merely releasing and re-opening the device does not clear that
// condition.
func (u *Device) Recover() error {
	var errs []error
	for _, endpoint := range [...]uint32{hostToDevice, deviceToHost} {
		if _, _, errno := syscall.Syscall(
			syscall.SYS_IOCTL,
			u.f.Fd(),
			usbdevfsClearHalt,
			uintptr(unsafe.Pointer(&endpoint)),
		); errno != 0 {
			errs = append(errs, fmt.Errorf("clear halt on endpoint 0x%02x: %w", endpoint, errno))
		}
	}

	return errors.Join(errs...)
}

// Reset performs a USB function reset. Clearing halted endpoints is enough
// for a normal interrupted transfer, but the iX500 can also enter a state
// where subsequent command responses overflow after a failed scan. A function
// reset makes the kernel re-enumerate the scanner and restores its command
// channel before the daemon opens it again.
func (u *Device) Reset() error {
	if _, _, errno := syscall.Syscall(
		syscall.SYS_IOCTL,
		u.f.Fd(),
		usbdevfsReset,
		0,
	); errno != 0 {
		return errno
	}
	return nil
}

func badName(name string) bool {
	if name == "" {
		return true
	}

	r, _ := utf8.DecodeRuneInString(name)
	if !unicode.IsDigit(r) {
		return true
	}
	for _, r := range name {
		if r != '.' && r != '-' && !unicode.IsDigit(r) {
			return true
		}
	}
	return false
}

func FindDevice() (*Device, error) {
	entries, err := os.ReadDir(usbDevicesRoot)
	if err != nil {
		return nil, err
	}

	for _, entry := range entries {
		name := entry.Name()
		if badName(name) {
			continue
		}

		idProduct, err := os.ReadFile(filepath.Join(usbDevicesRoot, name, "idProduct"))
		if err != nil {
			return nil, err
		}
		idVendor, err := os.ReadFile(filepath.Join(usbDevicesRoot, name, "idVendor"))
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(string(idProduct)) == product &&
			strings.TrimSpace(string(idVendor)) == vendor {
			return newDevice(name)
		}
	}

	return nil, fmt.Errorf("device with product=%q vendor=%q not found", product, vendor)
}
