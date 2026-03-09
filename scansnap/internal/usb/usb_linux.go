package usb

import (
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
