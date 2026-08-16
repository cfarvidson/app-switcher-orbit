#!/bin/bash
set -e

SCHEME="Orbit"
PROJECT="Orbit.xcodeproj"

echo "Testing $SCHEME..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' test
