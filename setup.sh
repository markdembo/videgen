#!/bin/bash
# VidGen setup — run this once to generate the Xcode project
set -e

if ! command -v xcodegen &> /dev/null; then
  echo "Installing XcodeGen..."
  brew install xcodegen
fi

echo "Generating Xcode project..."
xcodegen generate

echo ""
echo "Done! Open VidGen.xcodeproj in Xcode, connect your iPhone,"
echo "select your team in Signing & Capabilities, then Run."
echo ""
echo "Note: With a free Apple ID the app expires every 7 days."
echo "Re-run 'xcodegen generate' and re-build to refresh."
