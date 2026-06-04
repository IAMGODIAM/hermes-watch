# Hermes Watch — Apple Watch ↔ Hermes Agent Voice Communication

Two-way voice communication between an Apple Watch and the Hermes AI agent, relayed through an iPhone.

## Architecture

```
┌──────────────┐  WatchConnectivity  ┌──────────────┐  WebSocket  ┌──────────────────┐
│  Apple Watch  │ ──────────────────► │    iPhone     │ ──────────► │  Hermes Voice    │
│  (Watch App)  │ ◄────────────────── │  (Relay App)  │ ◄────────── │  Server (Python)  │
└──────────────┘   TTS audio back     └──────────────┘  TTS audio  └────────┬─────────┘
                                                                            │ HTTP
                                                                            ▼
                                                                   ┌──────────────────┐
                                                                   │  Hermes Gateway   │
                                                                   │  (Boardroom 8420) │
                                                                   │  → Hermie (LLM)   │
                                                                   └──────────────────┘
```

## Project Structure

```
hermes-watch/
├── HermesWatch/                    # Xcode project root
│   ├── HermesWatchWatchApp/        # WatchOS app target
│   │   ├── HermesWatchApp.swift    # App entry point
│   │   ├── ContentView.swift       # Watch UI (hold-to-talk)
│   │   ├── VoiceSessionManager.swift # Audio + WCSession logic
│   │   └── Info.plist              # Mic permission + background audio
│   │
│   ├── HermesWatchiPhoneApp/       # iPhone relay app target
│   │   ├── HermesWatchApp.swift    # App entry point
│   │   ├── ContentView.swift       # iPhone UI (status + config)
│   │   ├── iPhoneRelayManager.swift # WCSession + WebSocket bridge
│   │   └── Info.plist              # Local network permission
│   │
│   └── HermesWatchShared/          # Shared code (future)
│
├── HermesVoiceBackend/             # Python voice server
│   └── hermes_voice_server.py      # WebSocket server
│
└── README.md
```

## Prerequisites

### Hardware
- **Mac** with macOS 14+ (required — Xcode is macOS-only)
- **iPhone** with iOS 17+
- **Apple Watch** with watchOS 10+
- All devices on the **same WiFi network**

### Software
- **Xcode 15+** (free from Mac App Store)
- **Python 3.10+** (on the machine running Hermes Gateway)
- **Hermes Gateway / Boardroom** running and accessible

### Python Dependencies
```bash
pip install websockets av edge-tts torch torchaudio openai-whisper aiohttp numpy
```

## Setup & Build

### Step 1: Open in Xcode

1. Copy the `hermes-watch` folder to your Mac (e.g., `~/Desktop/hermes-watch/`)
2. Open Xcode → File → New → Project
3. Select **App** → Choose **SwiftUI** interface
4. Name: `Hermes Watch`
5. **Important**: Check "Include Watch App" during project creation

### Step 2: Add Files to Xcode Project

1. In Xcode's Project Navigator, delete the auto-generated template files
2. Drag the source files from this scaffold into the appropriate targets:
   - `HermesWatchWatchApp/` files → Watch App target
   - `HermesWatchiPhoneApp/` files → iPhone App target
3. Ensure files are added to the correct **Target Membership**

### Step 3: Configure Signing

1. Select the project → Signing & Capabilities
2. Set your **Team** (Apple Developer account — free works for device testing)
3. Set unique **Bundle Identifiers**:
   - iPhone: `com.yourname.hermeswatch`
   - Watch: `com.yourname.hermeswatch.watchkitapp`
   - Watch Extension: `com.yourname.hermeswatch.watchkitapp.watchkitextension`

### Step 4: Add Required Capabilities

**iPhone App target:**
- Background Modes: ✅ Audio, ✅ Background fetch, ✅ Background processing
- App Sandbox: ✅ Network: Incoming & Outgoing connections

**Watch App target:**
- Background Modes: ✅ Audio
- Privacy - Microphone Usage Description: "Hermes Watch needs microphone access..."

### Step 5: Build & Run

1. Select the **iPhone scheme** first → Run (⌘R)
2. Then select the **Watch scheme** → Run (⌘R)
3. Both apps install on their respective devices

### Step 6: Start the Hermes Voice Server

On the machine running your Hermes Gateway (e.g., Monte-Cristo):

```bash
cd ~/hermes-watch/HermesVoiceBackend
pip install websockets av edge-tts torch torchaudio openai-whisper aiohttp numpy

# Start the voice server
python hermes_voice_server.py \
    --host 0.0.0.0 \
    --port 8422 \
    --hermes-host localhost \
    --hermes-port 8420 \
    --whisper-model base \
    --tts-voice en-US-GuyNeural
```

**Note**: Use port 8422 (or any free port) for the voice server — don't conflict with Boardroom's 8420.

### Step 7: Configure the iPhone App

1. Open the Hermes Relay app on your iPhone
2. Enter the **IP address** of the machine running `hermes_voice_server.py`
3. Enter the **port** (default: 8422)
4. Tap **Connect**
5. Verify both "Watch" and "Hermes" show **Connected** (green)

### Step 8: Use It

1. Open **Hermes Watch** on your Apple Watch
2. **Press and hold** the microphone button
3. Speak your message
4. **Release** to send
5. Wait for Hermes to respond — audio plays automatically on the Watch

## Configuration

### TTS Voice Options

Edit in `hermes_voice_server.py` or pass via CLI:

| Voice | Description |
|-------|-------------|
| `en-US-GuyNeural` | Male, US English (default) |
| `en-US-JennyNeural` | Female, US English |
| `en-US-AriaNeural` | Female, US English (warm) |
| `en-GB-SoniaNeural` | Female, British English |

### Whisper Model Options

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| `tiny` | 75MB | Fastest | Low |
| `base` | 140MB | Fast | Good (default) |
| `small` | 460MB | Medium | Better |
| `medium` | 1.5GB | Slow | Best |

## Troubleshooting

### "iPhone not reachable" on Watch
- Ensure iPhone app is running (foreground or background)
- Both devices must be on same WiFi or paired via Bluetooth
- Check WCSession activation in iPhone console

### "Hermes not connected" on iPhone
- Verify `hermes_voice_server.py` is running
- Check firewall allows the port
- Test: `curl http://<host>:<port>/ws/voice`

### No audio playback on Watch
- Check Watch volume (Settings → Sounds)
- Verify Bluetooth audio routing if using AirPods
- Check `AVAudioSession` category is `.playAndRecord`

### Transcription not working
- Whisper model downloads on first run (~140MB for `base`)
- Check internet connection for model download
- Try `whisper-model tiny` for faster loading

### Build errors in Xcode
- Ensure minimum deployment targets: iOS 17.0, watchOS 10.0
- Check all files have correct Target Membership
- Clean build folder: Product → Clean Build Folder (⌘⇧K)

## Security Notes

- All communication stays on your **local network** by default
- WebSocket uses `ws://` (not encrypted) — fine for local network
- For remote access, use `wss://` with TLS or tunnel through Cloudflare
- No audio is stored permanently — all processing is real-time
- The Watch app requests microphone permission on first use

## Future Enhancements

- [ ] Streaming audio (real-time, not record-then-send)
- [ ] On-device transcription (WatchOS 10+ Speech framework)
- [ ] Standalone Watch app (no iPhone relay, direct WiFi)
- [ ] Complication for quick access
- [ ] Siri Intent integration ("Ask Hermes...")
- [ ] Haptic feedback for response ready
- [ ] Multiple Hermes agent selection
