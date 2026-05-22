# Microphone Access

Microphones use the `audio` entitlement. Add it for recording, voice commands, wake-word detection, speech-to-text, and audio analysis.

```bash
wendy project entitlements add audio
```

## Device Commands

List input and output devices:

```bash
wendy device audio list
```

Set the default audio device:

```bash
wendy device audio set-default --id 1
```

Monitor microphone levels:

```bash
wendy device audio monitor --id 1
wendy device audio monitor --id 1 --rate 20
```

Stream microphone audio:

```bash
wendy device audio listen --id 1
wendy device audio listen --id 1 --sample-rate 16000 --channels 1 --stdout
```

## App Configuration

```json
{
  "appId": "com.example.microphone",
  "version": "1.0.0",
  "entitlements": [
    { "type": "audio" }
  ]
}
```
