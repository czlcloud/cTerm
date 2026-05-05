#!/bin/bash
set -e
cd "$(dirname "$0")/.."

# Build
swift build

# Create .app bundle
APP_DIR=".build/TerminalApp.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp .build/debug/TerminalApp "$APP_DIR/Contents/MacOS/"
cp Info.plist "$APP_DIR/Contents/"

# Sign the bundle (ad-hoc)
codesign --sign - --entitlements entitlements.plist --force --deep "$APP_DIR"

echo "App bundle: $APP_DIR"
echo "Run: open $APP_DIR"
