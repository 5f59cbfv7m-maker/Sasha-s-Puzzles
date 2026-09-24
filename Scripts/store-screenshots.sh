#!/bin/zsh
# App Store screenshots: a Debug build on the two simulators App Store Connect
# requires (iPhone 6.9" and iPad 13") and the Mac app, walked through the
# debug stages.
#
#   Scripts/store-screenshots.sh [language]      # default en → docs/store/en/
#   SIMULATORS= Scripts/store-screenshots.sh ja  # the Mac only
#
# Output is exactly the pixel size App Store Connect expects (1320×2868 and
# 2064×2752), and 1440×900 for the Mac (2880×1800 on a Retina screen).
# Landscape iPad frames come from --tray-trailing, which forces the landscape
# layout; rotate them 90° before uploading if you want true landscape.
set -euo pipefail
cd "$(dirname "$0")/.."

LANGUAGE=${1:-en}
OUT="docs/store/$LANGUAGE"
DD="${TMPDIR:-/tmp}/sashas-puzzles-screenshots"
BUNDLE=com.kirillrychkov.SashasPuzzle
typeset -A LOCALES=(en en_US ru ru_RU de de_DE fr fr_FR es es_ES it it_IT pt-BR pt_BR ja ja_JP ko ko_KR zh-Hans zh_CN)
LOCALE=${LOCALES[$LANGUAGE]:-en_US}
# Upload order: the first three show in search results, so a board mid-solve
# leads. Files are numbered so Finder sorts them the way they go in; `board`
# (an empty table under the faint guide) is left out on purpose.
STAGES=(hint library completed scattered dark settings)

# Cutting a big puzzle on a freshly booted simulator can outlast any fixed
# sleep, so wait until two thumbnails two seconds apart match (capped for
# screens that animate forever, like the confetti).
# The arguments are the capture command, completed with the output path.
settle() {
  local previous="" current
  sleep 4
  for _ in {1..10}; do
    "$@" "$DD/probe.png" >/dev/null 2>&1
    current=$(sips -Z 16 "$DD/probe.png" --out "$DD/probe-s.png" >/dev/null && md5 -q "$DD/probe-s.png")
    [[ "$current" == "$previous" ]] && return
    previous=$current
    sleep 2
  done
}

# SIMULATORS= (empty) shoots only the Mac.
for DEVICE in ${(s:,:)${SIMULATORS-iPhone 17 Pro Max,iPad Pro 13-inch (M5)}}; do
  UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [[ -n "$UDID" ]] || { echo "No simulator named '$DEVICE' — add it in Xcode › Settings › Components"; exit 1; }
  # The iPad status bar shows the date in the simulator's own language, so the
  # simulator is switched to the screenshot language (and restored at the end).
  PREVIOUS_LANGUAGES=$(xcrun simctl spawn "$UDID" defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n()"' || true)
  PREVIOUS_LOCALE=$(xcrun simctl spawn "$UDID" defaults read -g AppleLocale 2>/dev/null || true)
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  if [[ "$(xcrun simctl spawn "$UDID" defaults read -g AppleLocale 2>/dev/null)" != "$LOCALE" ]]; then
    xcrun simctl spawn "$UDID" defaults write -g AppleLanguages -array "$LANGUAGE"
    xcrun simctl spawn "$UDID" defaults write -g AppleLocale "$LOCALE"
    xcrun simctl shutdown "$UDID"
    xcrun simctl boot "$UDID"
    xcrun simctl bootstatus "$UDID" -b >/dev/null
  fi
  xcodebuild -quiet -project JigsawPuzzle.xcodeproj -scheme JigsawPuzzle -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" build
  xcrun simctl install "$UDID" "$DD/Build/Products/Debug-iphonesimulator/Sasha's Puzzles.app"
  # The classic 9:41 status bar; the date's language follows the simulator's
  # own setting, not -AppleLanguages.
  xcrun simctl status_bar "$UDID" override --time 9:41 --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null

  DIR="$OUT/${DEVICE// /-}"
  mkdir -p "$DIR"
  rm -f "$DIR"/*.png
  N=0
  for STAGE in $STAGES; do
    N=$((N + 1))
    xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null || true
    xcrun simctl launch "$UDID" $BUNDLE --stage "$STAGE" --clear-saves \
      -AppleLanguages "($LANGUAGE)" -onboarding YES -appearance light >/dev/null
    settle xcrun simctl io "$UDID" screenshot
    xcrun simctl io "$UDID" screenshot "$DIR/$N-$STAGE.png" >/dev/null 2>&1
    echo "$DIR/$N-$STAGE.png"
  done
  xcrun simctl status_bar "$UDID" clear >/dev/null
  if [[ -n "$PREVIOUS_LOCALE" && "$PREVIOUS_LOCALE" != "$LOCALE" && -z "${KEEP_SIM_LANGUAGE:-}" ]]; then
    xcrun simctl spawn "$UDID" defaults write -g AppleLanguages -array ${(s:,:)PREVIOUS_LANGUAGES}
    xcrun simctl spawn "$UDID" defaults write -g AppleLocale "$PREVIOUS_LOCALE"
    xcrun simctl shutdown "$UDID"
  fi
done

# The Mac app runs on this Mac for real, so it is built under its own bundle
# ID: `--clear-saves` then empties a throwaway sandbox container instead of the
# family's saved games and photos. Ad-hoc signed, it needs no profile.
MAC_APP="$DD/Build/Products/Debug/Sasha's Puzzles.app"
xcodebuild -quiet -project JigsawPuzzle.xcodeproj -scheme JigsawPuzzle -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DD" \
  PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE.screenshots CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
DIR="$OUT/Mac"
mkdir -p "$DIR"
rm -f "$DIR"/*.png
N=0
for STAGE in $STAGES; do
  N=$((N + 1))
  pkill -f "sashas-puzzles-screenshots/Build/" 2>/dev/null && sleep 1
  # A killed run leaves "no windows" as its saved state; ignore it. The
  # locale gives dates and numbers the screenshot language, like the simulators.
  open -n "$MAC_APP" --args -ApplePersistenceIgnoreState YES --stage "$STAGE" --clear-saves \
    -AppleLanguages "($LANGUAGE)" -AppleLocale "$LOCALE" -onboarding YES -appearance light
  sleep 1
  PID=$(pgrep -n -f "sashas-puzzles-screenshots/Build/")
  WID=""
  for _ in {1..30}; do
    WID=$(swift -e 'import CoreGraphics
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
      if let w = windows.first(where: { $0[kCGWindowOwnerPID as String] as? Int == Int(CommandLine.arguments[1])
          && ($0[kCGWindowBounds as String] as? [String: Double])?["Width"] == 1440 }) { print(w[kCGWindowNumber as String]!) }' "$PID")
    [[ -n "$WID" ]] && break
    # A background launch sometimes comes up with no window; a reopen event
    # makes SwiftUI create one, as clicking the Dock icon would.
    osascript -e "tell application id \"$BUNDLE.screenshots\" to reopen" 2>/dev/null || true
    sleep 2
  done
  [[ -n "$WID" ]] || { echo "The Mac window never reached 1440×900"; exit 1; }
  settle screencapture -x -o -l "$WID"
  screencapture -x -o -l "$WID" "$DD/window.png"
  # App Store Connect rejects transparency: fill the rounded window corners
  # with the title bar's own colour.
  swift -e 'import AppKit
    let a = CommandLine.arguments, rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    rep.colorAt(x: rep.pixelsWide / 2, y: 4)!.setFill()
    NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
    rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    NSGraphicsContext.current?.flushGraphics()
    try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))' "$DD/window.png" "$DIR/$N-$STAGE.png"
  echo "$DIR/$N-$STAGE.png"
done
pkill -f "sashas-puzzles-screenshots/Build/" 2>/dev/null || true
