# Bluetooth Access

Bluetooth access is used for BLE sensors, controllers, audio accessories, serial devices, and paired peripherals.

```bash
wendy project entitlements add bluetooth
```

Use a mode when your app needs one:

```bash
wendy project entitlements add bluetooth --mode kernel
wendy project entitlements add bluetooth --mode bluez
```

Use `kernel` for low-level HCI socket access. Use `bluez` for standard Linux Bluetooth workflows through BlueZ.

## Device Commands

Scan for peripherals:

```bash
wendy device bluetooth list
```

Connect, disconnect, and forget a peripheral:

```bash
wendy device bluetooth connect AA:BB:CC:DD:EE:FF
wendy device bluetooth connect AA:BB:CC:DD:EE:FF --pair=false --trust=false
wendy device bluetooth disconnect AA:BB:CC:DD:EE:FF
wendy device bluetooth forget AA:BB:CC:DD:EE:FF
```

## App Configuration

```json
{
  "appId": "com.example.bluetooth",
  "version": "1.0.0",
  "entitlements": [
    { "type": "bluetooth", "mode": "bluez" }
  ]
}
```
