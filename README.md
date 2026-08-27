# Speek

Native macOS dictation. Push-to-talk, fully on-device: Parakeet for transcription, S1-mini for transcript cleanup.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon (M1 or newer, 8GB+ RAM)
- xcodegen (`brew install xcodegen`) — the Xcode project is generated from `project.yml`

## Permissions Speek needs

- Microphone (required)
- Input Monitoring (required, for the global hotkey)
- Accessibility (recommended; falls back to clipboard paste if denied)

## First-time setup

```bash
cd Speek
./scripts/fetch-llama.sh   # downloads the pinned llama.cpp xcframework into Vendor/ (gitignored)
xcodegen generate
open Speek.xcodeproj
```

The Xcode project file is gitignored — regenerate it from `project.yml` whenever the dependency or target structure changes. Source files live under `Speek/`; tests under `SpeekTests/`.

The first time you run the app, FluidAudio downloads the Parakeet TDT v2 model (~600MB) into `~/Library/Caches/FluidAudio/`, and Speek downloads the s1-mini polish model (~484MB) into `~/Library/Application Support/Speek/Models/`. Subsequent launches use the cached models.

## Build + test from CLI

```bash
xcodebuild -project Speek.xcodeproj -scheme Speek -configuration Debug \
  -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" -quiet

xcodebuild test -project Speek.xcodeproj -scheme Speek \
  -destination 'platform=macOS' -only-testing:SpeekTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" -quiet
```

## Architecture (one-line tour)

`HotkeyManager` (Fn push-to-talk via `CGEventTap`) → `AudioCaptureService` (16kHz mono PCM via `AVAudioEngine`) → `ParakeetEngine` (FluidAudio Parakeet TDT v2 on the Apple Neural Engine; live preview streams from Apple's on-device `SpeechAnalyzer` via `SpeechPreviewEngine`, with a Parakeet re-decode loop as fallback) → `FormattingPipeline` (`RuleStage` for custom vocabulary and dictated punctuation commands, then `S1PolishStage` — s1-mini via llama.cpp/Metal — for fillers, self-corrections, punctuation, casing, and spoken numbers/dates) → `CompositeInjector` (Accessibility API primary → synthesized keystrokes via `TypingInjector` → clipboard copy when no editable target). Orchestrated by `DictationSession`; `CorrectionLearner` watches post-insertion edits to grow the custom vocabulary. Settings persist locally in `UserDefaults` via `SyncStore`.

Two sibling subsystems share the same FluidAudio stack: meeting transcription (`SystemAudioTapService` system-audio capture → Parakeet → `MeetingDiarizer` speaker diarization → `SpeakerAttributor`) and Read Aloud (`NeuralSpeechEngine`, Kokoro-82M TTS on the ANE, with ranked `AVSpeechSynthesizer` voices as fallback).

## Credits

- Transcript cleanup: [S1-mini](https://huggingface.co/superwhisper/s1-mini) by Superwhisper (Apache 2.0), run on-device via [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT).
- Transcription, diarization, and neural TTS: [FluidAudio](https://github.com/FluidInference/FluidAudio).

## Spec & plan

- Spec: `~/tara/docs/superpowers/specs/2026-05-04-speek-design.md`
- Plan: `~/tara/docs/superpowers/plans/2026-05-04-speek.md`
