#!/bin/zsh
# Builds two copies of the spike into spike/build/:
#   EarSaxSpike.app            normal app (what direct download would ship)
#   EarSaxSpikeSandboxed.app   App Sandbox on (what the Mac App Store requires) - answers decision D4
# No Xcode project: swiftc + a hand-made bundle, ad-hoc signed.
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
swiftc -swift-version 6 -O -target arm64-apple-macos15.0 -parse-as-library \
  -o build/EarSaxSpike Sources/*.swift

make_app() { # name bundle-id [entitlements]
  local app="build/$1.app"
  rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
  cp build/EarSaxSpike "$app/Contents/MacOS/EarSaxSpike"
  sed -e "s/BUNDLE_ID/$2/" -e "s/BUNDLE_NAME/$1/" Info.plist > "$app/Contents/Info.plist"
  local extra=(); [[ -n "${3:-}" ]] && extra=(--entitlements "$3")
  codesign --force --sign - "${extra[@]}" "$app"
  echo "built $app"
}
make_app EarSaxSpike app.earsax.spike
make_app EarSaxSpikeSandboxed app.earsax.spike.sandboxed Sandbox.entitlements
