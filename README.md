# Speakboard

A macOS menu-bar app that lets you dictate text into any application with a global hotkey. Press the hotkey, speak, release — the transcription is copied to the clipboard and pasted into the frontmost window.

## How it works

```
Press hotkey → panel appears + recording starts
      ↓
   (speak)
      ↓
Release hotkey (long press) or press ↩ (short press)
      ↓
  Backend transcribes → result shown in panel
      ↓
Press ↩ → paste into frontmost app
Press Esc → close without pasting
```

Real-time partial transcriptions appear in the panel as you speak, so you can see the result forming before you release the hotkey.

## Architecture

```
speakboard-sw/          ← this repo (Swift frontend)
└── backend/            ← git submodule (Rust ASR backend)
```

The Rust backend ([speakboard-be-sherpa](https://github.com/sudoytang/speakboard-be-sherpa)) is a WebSocket server that streams real-time speech-to-text using the [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) model via [sherpa-rs](https://github.com/thewh1teagle/sherpa-rs). The Swift frontend launches it as a sidecar process and communicates over `ws://localhost:8080/ws`.

## Requirements

- macOS 14.0+
- Xcode Command Line Tools (`xcode-select --install`)
- Rust toolchain (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`)

## Setup

```bash
# Clone with submodule
git clone --recursive https://github.com/sudoytang/speakboard-sw.git
cd speakboard-sw

# Build the Rust backend (first run downloads the ~100 MB SenseVoice model)
cd backend && cargo build --release && cd ..

# Run the app
swift run
```

The app appears in the menu bar. On first launch, macOS may ask for microphone access and (for the paste feature) Accessibility permission.

## Usage

| Action | Behavior |
|--------|----------|
| Hold hotkey > 0.5 s | Long press — releasing the hotkey stops recording and triggers transcription |
| Tap hotkey < 0.5 s | Short press — panel stays open; press **↩** to stop recording and transcribe |
| **↩** (during recording, short press) | Stop recording + transcribe |
| **↩** (result shown) | Copy to clipboard + paste into frontmost app |
| **Esc** | Close panel without pasting |

The default hotkey is **⌃⌘Z**. You can change it in **Settings**.

## Settings

Open **Settings…** from the menu-bar icon (or press **⌘,** with the menu open).

| Section | Options |
|---------|---------|
| Hotkey | Click **Record** and press your desired key combination |
| Server | Port, inference threads |
| VAD | Silence RMS threshold, partial/gold silence durations, max segment length |
| Transcription | Minimum audio duration before transcription is attempted |
| Model | Custom model / tokens path (leave blank for auto-download) |

Settings take effect after clicking **Save & Restart Backend**.

## Permissions

| Permission | Why |
|------------|-----|
| Microphone | Capturing audio for speech recognition |
| Accessibility | Simulating ⌘V to paste into the frontmost app |

No Input Monitoring permission is required — the global hotkey uses the Carbon `RegisterEventHotKey` API.

## Supported languages

SenseVoice automatically detects the language. Supported: Chinese, English, Japanese, Korean, Cantonese.
