#!/bin/zsh
# Builds build/EarSax.app (release, Apple silicon), ad-hoc signed.
# ponytail: ad-hoc signing means macOS asks for the audio permission again after every build, and "Open at login"
# may refuse to register. Developer ID signing and notarization arrive in Phase 3.
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64
appBundle=build/EarSax.app
rm -rf "$appBundle" && mkdir -p "$appBundle/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --show-bin-path)/EarSax" "$appBundle/Contents/MacOS/EarSax"
cp AppBundle/Info.plist "$appBundle/Contents/Info.plist"
mkdir -p "$appBundle/Contents/Resources" && cp AppBundle/Resources/* "$appBundle/Contents/Resources/"   # the Ko-fi cup
codesign --force --sign - "$appBundle"
echo "built $appBundle"
