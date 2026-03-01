package models

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestUSBDevice_HumanReadable(t *testing.T) {
	tests := []struct {
		name   string
		device USBDevice
		want   string
	}{
		{
			name:   "name only",
			device: USBDevice{Name: "Jetson Orin Nano"},
			want:   "Jetson Orin Nano",
		},
		{
			name:   "with agent version",
			device: USBDevice{Name: "Jetson Orin Nano", AgentVersion: "2.1.0"},
			want:   "Jetson Orin Nano v2.1.0",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.device.HumanReadable()
			if got != tt.want {
				t.Errorf("HumanReadable() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestLANDevice_HumanReadable(t *testing.T) {
	tests := []struct {
		name   string
		device LANDevice
		want   string
	}{
		{
			name: "basic",
			device: LANDevice{
				DisplayName: "Wendy Dev",
				Hostname:    "wendyos-zestful-stork.local",
				Port:        50051,
			},
			want: "Wendy Dev @ wendyos-zestful-stork.local:50051",
		},
		{
			name: "with version",
			device: LANDevice{
				DisplayName:  "Wendy Dev",
				Hostname:     "wendyos-zestful-stork.local",
				Port:         50051,
				AgentVersion: "1.0.0",
			},
			want: "Wendy Dev @ wendyos-zestful-stork.local:50051 v1.0.0",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.device.HumanReadable()
			if got != tt.want {
				t.Errorf("HumanReadable() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestBluetoothDevice_HumanReadable(t *testing.T) {
	tests := []struct {
		name   string
		device BluetoothDevice
		want   string
	}{
		{
			name:   "name only",
			device: BluetoothDevice{DisplayName: "Wendy BT"},
			want:   "Wendy BT",
		},
		{
			name:   "with version and rssi",
			device: BluetoothDevice{DisplayName: "Wendy BT", AgentVersion: "1.2.3", RSSI: -45},
			want:   "Wendy BT v1.2.3 (RSSI: -45)",
		},
		{
			name:   "with version no rssi",
			device: BluetoothDevice{DisplayName: "Wendy BT", AgentVersion: "1.2.3"},
			want:   "Wendy BT v1.2.3",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.device.HumanReadable()
			if got != tt.want {
				t.Errorf("HumanReadable() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestDevicesCollection_IsEmpty(t *testing.T) {
	empty := &DevicesCollection{}
	if !empty.IsEmpty() {
		t.Error("IsEmpty() = false for empty collection, want true")
	}

	withUSB := &DevicesCollection{
		USBDevices: []USBDevice{{Name: "test"}},
	}
	if withUSB.IsEmpty() {
		t.Error("IsEmpty() = true for collection with USB device, want false")
	}

	withLAN := &DevicesCollection{
		LANDevices: []LANDevice{{Hostname: "test.local"}},
	}
	if withLAN.IsEmpty() {
		t.Error("IsEmpty() = true for collection with LAN device, want false")
	}

	withBT := &DevicesCollection{
		BluetoothDevices: []BluetoothDevice{{DisplayName: "bt"}},
	}
	if withBT.IsEmpty() {
		t.Error("IsEmpty() = true for collection with Bluetooth device, want false")
	}
}

func TestDevicesCollection_ToJSON(t *testing.T) {
	collection := &DevicesCollection{
		USBDevices: []USBDevice{
			{Name: "Jetson", VendorID: "0955", ProductID: "7045", IsWendyDevice: true},
		},
		LANDevices:         []LANDevice{},
		BluetoothDevices:   []BluetoothDevice{},
		EthernetInterfaces: []EthernetInterface{},
	}

	jsonStr, err := collection.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON() error = %v", err)
	}

	// Should be valid JSON.
	var parsed map[string]json.RawMessage
	if err := json.Unmarshal([]byte(jsonStr), &parsed); err != nil {
		t.Fatalf("ToJSON() produced invalid JSON: %v", err)
	}

	if _, ok := parsed["usbDevices"]; !ok {
		t.Error("ToJSON() missing usbDevices key")
	}

	if !strings.Contains(jsonStr, "Jetson") {
		t.Error("ToJSON() output missing device name")
	}
}

func TestInterfaceType_Constants(t *testing.T) {
	tests := []struct {
		iface InterfaceType
		want  string
	}{
		{InterfaceUSB, "usb"},
		{InterfaceEthernet, "ethernet"},
		{InterfaceLAN, "lan"},
		{InterfaceBluetooth, "bluetooth"},
	}

	for _, tt := range tests {
		if string(tt.iface) != tt.want {
			t.Errorf("InterfaceType = %q, want %q", string(tt.iface), tt.want)
		}
	}
}
