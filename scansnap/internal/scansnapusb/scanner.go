package scansnapusb

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"scansnap_buttond/internal/fss500"
	"scansnap_buttond/internal/turbojpeg"
	"scansnap_buttond/internal/usb"
)

type Config struct {
	Profile  fss500.ScanProfile
	Geometry fss500.ScanGeometry
}

func configFromEnv() Config {
	profile := fss500.ScanProfile(strings.TrimSpace(os.Getenv("SCAN_PROFILE")))
	switch profile {
	case fss500.ProfileTest300ResolutionOnly:
		return Config{
			Profile: profile,
			Geometry: fss500.ScanGeometry{
				Resolution: 300,
				WidthPx:    4960,
				HeightPx:   7016,
			},
		}
	case fss500.ProfileTest300Geometry:
		return Config{
			Profile: profile,
			Geometry: fss500.ScanGeometry{
				Resolution: 300,
				WidthPx:    2480,
				HeightPx:   3508,
			},
		}
	default:
		return Config{
			Profile: fss500.ProfileStable600,
			Geometry: fss500.ScanGeometry{
				Resolution: 600,
				WidthPx:    4960,
				HeightPx:   7016,
			},
		}
	}
}

func ScanToDir(dev *usb.Device, dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	cfg := configFromEnv()
	geometry := cfg.Geometry

	if err := fss500.Inquire(dev); err != nil {
		return err
	}
	if err := fss500.Preread(dev, geometry, cfg.Profile); err != nil {
		return err
	}
	if err := fss500.ModeSelectAuto(dev); err != nil {
		return err
	}
	if err := fss500.ModeSelectDoubleFeed(dev); err != nil {
		return err
	}
	if err := fss500.ModeSelectBackground(dev); err != nil {
		return err
	}
	if err := fss500.ModeSelectDropout(dev); err != nil {
		return err
	}
	if err := fss500.ModeSelectBuffering(dev); err != nil {
		return err
	}
	if err := fss500.ModeSelectPrepick(dev); err != nil {
		return err
	}
	if err := fss500.SetWindow(dev, geometry, cfg.Profile); err != nil {
		return err
	}
	if err := fss500.SendLut(dev); err != nil {
		return err
	}
	if err := fss500.SendQtable(dev); err != nil {
		return err
	}
	if err := fss500.LampOn(dev); err != nil {
		return err
	}
	if _, err := fss500.GetHardwareStatus(dev); err != nil {
		return err
	}

	pageNumber := 0
	for paper := 0; ; paper++ {
		if err := fss500.ObjectPosition(dev); err != nil {
			if err == fss500.ErrHopperEmpty {
				if paper == 0 {
					return fmt.Errorf("no document inserted")
				}
				break
			}
			return fmt.Errorf("object position: %w", err)
		}

		if err := fss500.StartScan(dev); err != nil {
			return fmt.Errorf("start scan: %w", err)
		}
		pixelSize, err := fss500.GetPixelSize(dev)
		if err != nil {
			return fmt.Errorf("get pixel size: %w", err)
		}
		if pixelSize.WidthPx > 0 {
			geometry.WidthPx = pixelSize.WidthPx
		}
		if pixelSize.HeightPx > 0 {
			geometry.HeightPx = pixelSize.HeightPx
		}

		type pageState struct {
			buf  *bytes.Buffer
			enc  *turbojpeg.Encoder
			rest []byte
		}
		states := [2]*pageState{}
		for side := 0; side < 2; side++ {
			var buf bytes.Buffer
			enc, err := turbojpeg.NewEncoder(&buf, 75, geometry.WidthPx, geometry.HeightPx)
			if err != nil {
				return err
			}
			states[side] = &pageState{
				buf:  &buf,
				enc:  enc,
				rest: make([]byte, 0, 16*3*geometry.WidthPx),
			}
		}

		for {
			donePaper := false
			for side := 0; side < 2; side++ {
				if err := fss500.Ric(dev, side); err != nil {
					return fmt.Errorf("ric side %d: %w", side, err)
				}

				resp, err := fss500.ReadData(dev, side)
				if err == fss500.ErrTemporaryNoData {
					time.Sleep(500 * time.Millisecond)
					continue
				}
				if err != nil && err != fss500.ErrEndOfPaper {
					return err
				}

				state := states[side]
				buf := append(state.rest, resp.Extra...)
				height := len(buf) / 3 / geometry.WidthPx
				chunk := buf[:((height/16)*16)*3*geometry.WidthPx]
				state.rest = buf[len(chunk):]

				if len(chunk) > 0 {
					state.enc.EncodePixels(chunk, len(chunk)/3/geometry.WidthPx)
				}

				if err == fss500.ErrEndOfPaper && side == 1 {
					donePaper = true
					break
				}
			}
			if donePaper {
				break
			}
		}

		for _, state := range states {
			if len(state.rest) > 0 {
				state.enc.EncodePixels(state.rest, len(state.rest)/3/geometry.WidthPx)
			}
			if err := state.enc.Flush(); err != nil {
				return err
			}
		}

		for side := 0; side < 2; side++ {
			pageNumber++
			pagePath := filepath.Join(dir, fmt.Sprintf("page_%04d.jpg", pageNumber))
			if err := os.WriteFile(pagePath, states[side].buf.Bytes(), 0o644); err != nil {
				return err
			}
		}
	}

	return nil
}
