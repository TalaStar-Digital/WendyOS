# Speaker Access

Speakers, USB audio interfaces, and playback devices use the same `audio` entitlement as microphones.

```bash
wendy project entitlements add audio
```

## Device Commands

List audio devices:

```bash
wendy device audio list
```

Set the output device as default:

```bash
wendy device audio set-default --id 2
```

Apps that play through ALSA defaults use the selected output device.

## App Configuration

```json
{
  "appId": "com.example.speaker",
  "version": "1.0.0",
  "entitlements": [
    { "type": "audio" }
  ]
}
```
