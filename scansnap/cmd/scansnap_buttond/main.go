package main

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"time"

	"scansnap_buttond/internal/fss500"
	"scansnap_buttond/internal/scansnapusb"
	"scansnap_buttond/internal/usb"
)

const (
	processScript = "/etc/scanbd/scripts/scan.sh"
	pollInterval  = 500 * time.Millisecond
	scanDebounce  = 5 * time.Second
)

func main() {
	log.Printf("Starting ScanSnap iX500 single-owner daemon")
	log.Printf("Button press starts scan -> OCR -> upload pipeline")
	log.Printf("Current USB-native scan path is fixed at duplex color 600dpi")

	var lastScan time.Time
	for {
		dev, err := usb.FindDevice()
		if err != nil {
			log.Printf("Scanner not found: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}

		log.Printf("USB device opened - waiting for button press")
		if err := waitLoop(dev, &lastScan); err != nil {
			log.Printf("Scanner loop ended: %v", err)
		}
		if err := dev.Close(); err != nil {
			log.Printf("Device close warning: %v", err)
		}
		time.Sleep(2 * time.Second)
	}
}

func waitLoop(dev *usb.Device, lastScan *time.Time) error {
	var lastStatus string
	for {
		status, err := fss500.GetHardwareStatus(dev)
		if err != nil {
			return fmt.Errorf("get hardware status: %w", err)
		}

		paperLoaded := !status.Hopper
		statusLine := fmt.Sprintf("paper_loaded=%t scan_button=%t", paperLoaded, status.ScanSw)
		if statusLine != lastStatus {
			log.Printf("HW status changed: %s", statusLine)
			lastStatus = statusLine
		}

		if status.ScanSw && time.Since(*lastScan) > scanDebounce {
			*lastScan = time.Now()
			if err := performScan(dev); err != nil {
				log.Printf("Scan failed: %v", err)
			} else {
				log.Printf("Scan completed")
			}
		}

		if paperLoaded {
			time.Sleep(50 * time.Millisecond)
		} else {
			time.Sleep(pollInterval)
		}
	}
}

func performScan(dev *usb.Device) error {
	workdir, err := os.MkdirTemp("/tmp", "scan-")
	if err != nil {
		return err
	}

	log.Printf("Scanning to %s", workdir)
	if err := scansnapusb.ScanToDir(dev, workdir); err != nil {
		_ = os.RemoveAll(workdir)
		return err
	}

	cmd := exec.Command(processScript)
	cmd.Env = append(os.Environ(), "SCANNED_DIR="+workdir)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	log.Printf("Invoking processing pipeline")
	return cmd.Run()
}
