#!/bin/bash
# Builds llama.cpp and the embedded server (iOS/Engine) into build/ios-engine/<sdk>/libLlamaMobile.a.
# Xcode runs it in the Llama-iOS "Build embedded llama.cpp" phase; by hand: scripts/build-ios-engine.sh iphoneos
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${1:-${PLATFORM_NAME:-iphoneos}}"
case "$SDK" in iphoneos|iphonesimulator) ;; *) echo "Unsupported SDK: $SDK" >&2; exit 1;; esac
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SOURCE="$ROOT/build/llama.cpp"
OUTPUT="$ROOT/build/ios-engine/$SDK"

# The only llama.cpp pin for iOS. Keep it on the release the macOS app downloads
# (LlamaBinaries.targetVersion); the commit guards against a moved tag.
TAG=b11630
COMMIT=6868a52cb337450658006ad2f9281c2eb63f1666

MAC_TAG=$(sed -n 's/.*targetVersion = LlamaVersion(parsing: "\(b[0-9]*\)").*/\1/p' "$ROOT/Llama/Engine/LlamaBinaries.swift")
if [ "$MAC_TAG" != "$TAG" ]; then
  echo "warning: the iOS engine is pinned to llama.cpp $TAG but the macOS app uses $MAC_TAG"
fi

if [ ! -d "$SOURCE/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$SOURCE"
fi
if [ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]; then
  git -C "$SOURCE" fetch --depth 1 origin tag "$TAG"
  git -C "$SOURCE" checkout --detach "$TAG"
fi
if [ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]; then
  echo "llama.cpp $TAG is not commit $COMMIT in $SOURCE" >&2
  exit 1
fi

METAL=ON
if [ "$SDK" = iphonesimulator ]; then METAL=OFF; fi
# The shallow clone cannot derive the build number, so pass it with the commit.
cmake -S "$ROOT/iOS/Engine" -B "$OUTPUT" \
  -DLLAMA_SOURCE="$SOURCE" -DLLAMA_BUILD_NUMBER="${TAG#b}" -DLLAMA_BUILD_COMMIT="${COMMIT:0:8}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DGGML_METAL="$METAL" -DGGML_BLAS=OFF
cmake --build "$OUTPUT" --target mobile-server --parallel "${LLAMA_BUILD_JOBS:-6}"
# Combine the built dependency archives into one library for Xcode.
find "$OUTPUT" -name '*.a' ! -name 'libLlamaMobile.a' -print > "$OUTPUT/libraries.txt"
/usr/bin/libtool -static -o "$OUTPUT/libLlamaMobile.a" -filelist "$OUTPUT/libraries.txt"
