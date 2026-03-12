#!/bin/bash
set -e

SCHEME="Orbit"
PROJECT="Orbit.xcodeproj"
CONFIG="Release"

echo "Building $SCHEME..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" -destination 'platform=macOS' build 2>&1 | tail -5

BUILD_DIR=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $3}')

if [ -d "$BUILD_DIR/$SCHEME.app" ]; then
    rm -rf "./$SCHEME.app"
    cp -R "$BUILD_DIR/$SCHEME.app" "./$SCHEME.app"
    echo "Copied to ./$SCHEME.app"
else
    echo "Build product not found at $BUILD_DIR/$SCHEME.app"
    exit 1
fi
