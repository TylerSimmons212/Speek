# Speek

Native macOS dictation. Push-to-talk, fully on-device, hybrid regex + Apple Foundation Models formatting.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon (M1 or newer, 8GB+ RAM)
- Apple Intelligence enabled (System Settings → Apple Intelligence)
- xcodegen (`brew install xcodegen`) — the Xcode project is generated from `project.yml`

## Permissions Speek needs

- Microphone (required)
- Input Monitoring (required, for the global hotkey)
- Accessibility (recommended; falls back to clipboard paste if denied)

## First-time setup

```bash
cd Speek
xcodegen generate
open Speek.xcodeproj
```

The Xcode project file is gitignored — regenerate it from `project.yml` whenever the dependency or target structure changes. Source files live under `Speek/`; tests under `SpeekTests/`.

The first time you run the app, FluidAudio will download the Parakeet TDT v2 model from HuggingFace (~600MB) into `~/Library/Caches/FluidAudio/`. Subsequent launches use the cached model.

## Build + test from CLI

```bash
xcodebuild -project Speek.xcodeproj -scheme Speek -configuration Debug \
  -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" -quiet

xcodebuild test -project Speek.xcodeproj -scheme Speek \
  -destination 'platform=macOS' -only-testing:SpeekTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" -quiet
```

Local builds skip entitlements signing because `com.apple.developer.foundation-models` requires a development cert provisioned for Apple Intelligence. The entitlement still ships in the bundle and applies when signing for distribution.

## Architecture (one-line tour)

`HotkeyManager` (Fn push-to-talk via `CGEventTap`) → `AudioCaptureService` (16kHz mono PCM via `AVAudioEngine`) → `ParakeetEngine` (FluidAudio, Apple Neural Engine) → `FormattingPipeline` (`RuleStage` regex cleanup → `FMPolishStage` Apple Foundation Models with `@Generable`) → `CompositeInjector` (Accessibility API primary, clipboard paste fallback). Orchestrated by `DictationSession`. Settings persist via `NSUbiquitousKeyValueStore` for cross-Mac roaming.

## Spec & plan

- Spec: `~/tara/docs/superpowers/specs/2026-05-04-speek-design.md`
- Plan: `~/tara/docs/superpowers/plans/2026-05-04-speek.md`
