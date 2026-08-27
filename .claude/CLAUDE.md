# Speek — Project Context

Native **macOS dictation** app. Push-to-talk, fully **on-device**: transcription
via FluidAudio (Parakeet TDT v2), transcript cleanup via `S1PolishStage` —
s1-mini ("S1-mini" by Superwhisper, a 0.6B Qwen3 fine-tune, official Q4_K_M
GGUF run through llama.cpp/Metal) — preceded by a slim `RuleStage` (custom
vocabulary + dictated punctuation commands only). Also ships meeting
transcription (system-audio tap → Parakeet → FluidAudio speaker diarization)
and Read Aloud (Kokoro-82M TTS via FluidAudio). Settings persist in
`UserDefaults` via `SyncStore`. Portable code project — work on it directly in
this repo on any device.

## Requirements

- macOS 26 (Tahoe)+, Apple Silicon
- `xcodegen` (`brew install xcodegen`) — the `.xcodeproj` is gitignored and
  generated from `project.yml`
- Swift 6.0. Permissions the app needs: Microphone + Input Monitoring (global hotkey)

## First-time setup

```bash
cd Speek && ./scripts/fetch-llama.sh && xcodegen generate && open Speek.xcodeproj
```
`fetch-llama.sh` pulls the pinned llama.cpp xcframework into `Vendor/`
(gitignored) — required before the first build. First app run downloads the
Parakeet model (~600 MB) to `~/Library/Caches/FluidAudio/` and the s1-mini
GGUF (~484 MB) to `~/Library/Application Support/Speek/Models/`.
S1PolishStage integration tests skip themselves when the GGUF is absent.

## Build + test (CLI)

```bash
xcodebuild -project Speek.xcodeproj -scheme Speek -configuration Debug \
  -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" -quiet

xcodebuild test -project Speek.xcodeproj -scheme Speek \
  -destination 'platform=macOS' -only-testing:SpeekTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" -quiet
```

## Structure

- `Speek/` — source (SwiftUI + macOS APIs)
- `SpeekTests/` — tests
- `project.yml` — xcodegen spec (regenerate `.xcodeproj` after changing deps/targets)

For SwiftUI work, prefer the `swiftui-expert` skill.
