#!/bin/bash
# Fetches the pinned llama.cpp xcframework used by S1PolishStage (s1-mini GGUF inference).
# The xcframework is gitignored — run this once after cloning (xcodegen references it).
set -euo pipefail
TAG="b10655"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Vendor"
if [ -d "$DEST/llama.xcframework" ] && [ "$(cat "$DEST/.llama-version" 2>/dev/null)" = "$TAG" ]; then
  echo "llama.xcframework $TAG already present."
  exit 0
fi
echo "Downloading llama.cpp $TAG xcframework…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --progress-bar \
  "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip" \
  -o "$TMP/llama.zip"
rm -rf "$DEST/llama.xcframework"
unzip -q "$TMP/llama.zip" -d "$TMP/unzipped"
# The zip may nest the xcframework one level down — find it.
FOUND="$(find "$TMP/unzipped" -maxdepth 3 -name 'llama.xcframework' -type d | head -1)"
[ -n "$FOUND" ] || { echo "llama.xcframework not found in archive" >&2; exit 1; }
mkdir -p "$DEST"
mv "$FOUND" "$DEST/llama.xcframework"
echo "$TAG" > "$DEST/.llama-version"
echo "Installed Vendor/llama.xcframework ($TAG)."
