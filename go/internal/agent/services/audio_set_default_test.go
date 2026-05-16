package services

import (
	"testing"

	agentpb "github.com/wendylabsinc/wendy/proto/gen/agentpb"
)

// TestDecodeALSAID verifies that decodeALSAID correctly inverts the encoding
// applied by parseALSAOutput: id = ((card << 8) | device) + 1.
func TestDecodeALSAID(t *testing.T) {
	tests := []struct {
		name       string
		id         uint32
		wantCard   uint64
		wantDevice uint64
	}{
		{
			name:       "card 0 device 0",
			id:         1, // ((0<<8)|0)+1
			wantCard:   0,
			wantDevice: 0,
		},
		{
			name:       "card 0 device 1",
			id:         2, // ((0<<8)|1)+1
			wantCard:   0,
			wantDevice: 1,
		},
		{
			name:       "card 1 device 0",
			id:         257, // ((1<<8)|0)+1
			wantCard:   1,
			wantDevice: 0,
		},
		{
			name:       "card 1 device 1",
			id:         258, // ((1<<8)|1)+1
			wantCard:   1,
			wantDevice: 1,
		},
		{
			name:       "card 2 device 3",
			id:         516, // ((2<<8)|3)+1
			wantCard:   2,
			wantDevice: 3,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			card, device := decodeALSAID(tt.id)
			if card != tt.wantCard {
				t.Errorf("decodeALSAID(%d) card = %d; want %d", tt.id, card, tt.wantCard)
			}
			if device != tt.wantDevice {
				t.Errorf("decodeALSAID(%d) device = %d; want %d", tt.id, device, tt.wantDevice)
			}
		})
	}
}

// TestDecodeALSARoundTrip verifies that encoding and decoding are inverse operations.
func TestDecodeALSARoundTrip(t *testing.T) {
	for card := uint64(0); card < 4; card++ {
		for dev := uint64(0); dev < 4; dev++ {
			// Replicate the encoding from parseALSAOutput.
			encoded := ((card << 8) | dev) + 1
			id := uint32(encoded)

			gotCard, gotDevice := decodeALSAID(id)
			if gotCard != card || gotDevice != dev {
				t.Errorf("round-trip card=%d device=%d: got card=%d device=%d", card, dev, gotCard, gotDevice)
			}
		}
	}
}

// TestExtractJSONStringOrNumber verifies parsing of pw-dump JSON property lines.
func TestExtractJSONStringOrNumber(t *testing.T) {
	tests := []struct {
		line string
		want string
	}{
		{`"alsa.card": "0",`, "0"},
		{`"alsa.card": "1"`, "1"},
		{`"alsa.device": "0",`, "0"},
		{`"alsa.device": "2"`, "2"},
		{`"id": 42,`, "42"},
		{`"id": 42`, "42"},
		{`no colon here`, ""},
	}

	for _, tt := range tests {
		got := extractJSONStringOrNumber(tt.line)
		if got != tt.want {
			t.Errorf("extractJSONStringOrNumber(%q) = %q; want %q", tt.line, got, tt.want)
		}
	}
}

// TestExtractPactlPropertyValue verifies parsing of pactl list output property lines.
func TestExtractPactlPropertyValue(t *testing.T) {
	tests := []struct {
		line string
		want string
	}{
		{`alsa.card = "0"`, "0"},
		{`alsa.card = "1"`, "1"},
		{`alsa.device = "0"`, "0"},
		{`alsa.device = "3"`, "3"},
		{`alsa.card = 0`, "0"},
		{`no equals sign`, ""},
	}

	for _, tt := range tests {
		got := extractPactlPropertyValue(tt.line)
		if got != tt.want {
			t.Errorf("extractPactlPropertyValue(%q) = %q; want %q", tt.line, got, tt.want)
		}
	}
}

// TestParseALSAOutputIDEncoding verifies that parseALSAOutput uses the same
// encoding that decodeALSAID expects.
func TestParseALSAOutputIDEncoding(t *testing.T) {
	// Simulate aplay -l output with two devices.
	output := `**** List of PLAYBACK Hardware Devices ****
card 0: PCH [HDA Intel PCH], device 0: ALC236 Analog [ALC236 Analog]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 1: HDMI [HDA Intel HDMI], device 3: HDMI 0 [HDMI 0]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
`
	devices := parseALSAOutput(output, agentpb.AudioDeviceType_AUDIO_DEVICE_TYPE_OUTPUT)

	if len(devices) != 2 {
		t.Fatalf("parseALSAOutput: len = %d; want 2", len(devices))
	}

	// Verify card 0 device 0 → id 1.
	card, dev := decodeALSAID(devices[0].Id)
	if card != 0 || dev != 0 {
		t.Errorf("devices[0]: decoded card=%d device=%d; want card=0 device=0", card, dev)
	}

	// Verify card 1 device 3 → id ((1<<8)|3)+1 = 260.
	card, dev = decodeALSAID(devices[1].Id)
	if card != 1 || dev != 3 {
		t.Errorf("devices[1]: decoded card=%d device=%d; want card=1 device=3", card, dev)
	}
}
