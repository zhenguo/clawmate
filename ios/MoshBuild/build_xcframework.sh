#!/bin/bash
# build_xcframework.sh — Compile mosh C++ into iOS static library
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOSH_SRC="$SCRIPT_DIR/mosh-src"
BUILD_DIR="$SCRIPT_DIR/build"
OUTPUT_DIR="$SCRIPT_DIR/../Frameworks"

IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
IOS_MIN="13.0"
ARCH="arm64"
CXX="$(xcrun --find clang++)"
AR="$(xcrun --find ar)"
PROTOC="$(which protoc)"

CXXFLAGS="-std=c++17 -target ${ARCH}-apple-ios${IOS_MIN} -isysroot ${IOS_SDK} \
  -I${MOSH_SRC} -I${BUILD_DIR}/proto_gen -I${SCRIPT_DIR} \
  -DHAVE_CONFIG_H \
  -fvisibility=hidden -Os -fPIC \
  -Wno-deprecated-declarations -Wno-unused-variable"

# Protobuf paths (host for protoc, need to cross-compile protobuf-lite for iOS)
PROTOBUF_HOST_DIR="/opt/homebrew/opt/protobuf"
OPENSSL_DIR="/opt/homebrew/opt/openssl"

echo "=== Step 1: Generate protobuf C++ sources ==="
mkdir -p "$BUILD_DIR/proto_gen/src/protobufs"
for proto in hostinput userinput transportinstruction; do
    "$PROTOC" \
        --cpp_out="$BUILD_DIR/proto_gen/src/protobufs" \
        --proto_path="$MOSH_SRC/src/protobufs" \
        "$MOSH_SRC/src/protobufs/${proto}.proto"
done
echo "   Protobuf sources generated."

echo "=== Step 2: Cross-compile protobuf-lite for iOS arm64 ==="
PROTOBUF_IOS_DIR="$BUILD_DIR/protobuf-ios"
if [ ! -f "$PROTOBUF_IOS_DIR/lib/libprotobuf-lite.a" ]; then
    mkdir -p "$PROTOBUF_IOS_DIR"
    PROTOBUF_SRC_VERSION=$(brew info protobuf --json | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['versions']['stable'])")
    PROTOBUF_SRC_DIR="$BUILD_DIR/protobuf-src"

    if [ ! -d "$PROTOBUF_SRC_DIR" ]; then
        echo "   Downloading protobuf source v${PROTOBUF_SRC_VERSION}..."
        cd "$BUILD_DIR"
        curl -sL "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_SRC_VERSION}/protobuf-${PROTOBUF_SRC_VERSION}.tar.gz" -o protobuf.tar.gz
        tar xzf protobuf.tar.gz
        mv "protobuf-${PROTOBUF_SRC_VERSION}" protobuf-src
        rm protobuf.tar.gz
    fi

    echo "   Building protobuf-lite for iOS arm64 via cmake..."
    ABSEIL_HOST="/opt/homebrew/opt/abseil"
    mkdir -p "$BUILD_DIR/protobuf-build-ios"
    cd "$BUILD_DIR/protobuf-build-ios"
    cmake "$PROTOBUF_SRC_DIR" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN \
        -DCMAKE_INSTALL_PREFIX="$PROTOBUF_IOS_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -Dprotobuf_BUILD_TESTS=OFF \
        -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
        -Dprotobuf_BUILD_SHARED_LIBS=OFF \
        -Dprotobuf_BUILD_LIBUPB=OFF \
        -Dprotobuf_ABSL_PROVIDER=package \
        -DCMAKE_PREFIX_PATH="$ABSEIL_HOST" \
        2>&1 | tail -5
    cmake --build . --target libprotobuf-lite -j$(sysctl -n hw.ncpu) 2>&1 | tail -5
    cmake --install . 2>&1 | tail -3
    echo "   Protobuf-lite built."
else
    echo "   Protobuf-lite already built, skipping."
fi

PROTOBUF_IOS_INCLUDE="$PROTOBUF_IOS_DIR/include"
PROTOBUF_IOS_LIB="$PROTOBUF_IOS_DIR/lib"
CXXFLAGS="$CXXFLAGS -I${PROTOBUF_IOS_INCLUDE}"

echo "=== Step 3: Compile mosh C++ sources ==="
mkdir -p "$BUILD_DIR/obj"

# List of source files to compile
SOURCES=(
    # crypto
    "$MOSH_SRC/src/crypto/base64.cc"
    "$MOSH_SRC/src/crypto/crypto.cc"
    "$MOSH_SRC/src/crypto/ocb_openssl.cc"
    # network
    "$MOSH_SRC/src/network/compressor.cc"
    "$MOSH_SRC/src/network/network.cc"
    "$MOSH_SRC/src/network/transportfragment.cc"
    # statesync
    "$MOSH_SRC/src/statesync/completeterminal.cc"
    "$MOSH_SRC/src/statesync/user.cc"
    # terminal
    "$MOSH_SRC/src/terminal/parser.cc"
    "$MOSH_SRC/src/terminal/parseraction.cc"
    "$MOSH_SRC/src/terminal/parserstate.cc"
    "$MOSH_SRC/src/terminal/terminal.cc"
    "$MOSH_SRC/src/terminal/terminaldispatcher.cc"
    "$MOSH_SRC/src/terminal/terminaldisplay.cc"
    "$MOSH_SRC/src/terminal/terminaldisplayinit.cc"
    "$MOSH_SRC/src/terminal/terminalframebuffer.cc"
    "$MOSH_SRC/src/terminal/terminalfunctions.cc"
    "$MOSH_SRC/src/terminal/terminaluserinput.cc"
    # frontend (overlay only, not mosh-client/mosh-server binaries)
    "$MOSH_SRC/src/frontend/terminaloverlay.cc"
    # util
    "$MOSH_SRC/src/util/locale_utils.cc"
    "$MOSH_SRC/src/util/select.cc"
    "$MOSH_SRC/src/util/swrite.cc"
    "$MOSH_SRC/src/util/timestamp.cc"
    "$MOSH_SRC/src/util/pty_compat.cc"
    # generated protobuf
    "$BUILD_DIR/proto_gen/src/protobufs/hostinput.pb.cc"
    "$BUILD_DIR/proto_gen/src/protobufs/userinput.pb.cc"
    "$BUILD_DIR/proto_gen/src/protobufs/transportinstruction.pb.cc"
    # FFI wrapper
    "$SCRIPT_DIR/mosh_client_ffi.cc"
)

OBJECTS=()
for src in "${SOURCES[@]}"; do
    obj="$BUILD_DIR/obj/$(basename "$src" .cc).o"
    echo "   Compiling $(basename "$src")..."
    $CXX $CXXFLAGS -c "$src" -o "$obj" \
        -I"$OPENSSL_DIR/include" \
        2>&1 | head -5
    OBJECTS+=("$obj")
done

echo "=== Step 4: Create static library ==="
STATIC_LIB="$BUILD_DIR/libmoshclient.a"
$AR rcs "$STATIC_LIB" "${OBJECTS[@]}"
echo "   Created $STATIC_LIB"

echo "=== Step 5: Create xcframework ==="
mkdir -p "$BUILD_DIR/headers"
cp "$SCRIPT_DIR/mosh_client_ffi.h" "$BUILD_DIR/headers/"

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/MoshClient.xcframework"
xcodebuild -create-xcframework \
    -library "$STATIC_LIB" \
    -headers "$BUILD_DIR/headers" \
    -output "$OUTPUT_DIR/MoshClient.xcframework"

echo ""
echo "=== Done ==="
echo "XCFramework created at: $OUTPUT_DIR/MoshClient.xcframework"
echo ""
echo "You also need to link these iOS system libraries:"
echo "  - libz.tbd"
echo "  - libcrypto.a (from OpenSSL, or use CommonCrypto adapter)"
echo "  - libprotobuf-lite.a (from $PROTOBUF_IOS_LIB)"
echo "  - libc++.tbd"
