# Speek — Project Context

Native **macOS dictation** app. Push-to-talk, fully **on-device**: transcription
via FluidAudio (Parakeet TDT v2), formatting via a hybrid of regex + Apple
Foundation Models. Portable code project — work on it directly in this repo on
any device.

## Requirements

- macOS 26 (Tahoe)+, Apple Silicon, Apple Intelligence enabled
- `xcodegen` (`brew install xcodegen`) — the `.xcodeproj` is gitignored and
  generated from `project.yml`
- Swift 6.0. Permissions the app needs: Microphone + Input Monitoring (global hotkey)

## First-time setup

```bash
cd Speek && xcodegen generate && open Speek.xcodeproj
```
First run downloads the Parakeet model (~600 MB) to `~/Library/Caches/FluidAudio/`.

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
