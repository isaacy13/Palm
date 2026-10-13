#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="$ROOT/Tools/PalmHostApp"
STAGE="$HOST/Prebuilt"
APP="$HOST/build/PalmHost.app"
IPA_APP="${PALM_NYXIAN_APP:-/tmp/palm-nyxian/Payload/Nyxian.app}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IDENTITY="${PALM_SIGN_IDENTITY:-Apple Development: Isaac Yeang (AT4W55YC44)}"
PROFILE="${PALM_PROFILE:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/b684b759-ad16-43c7-bd58-d3d388e670a2.mobileprovision}"

echo "host build start"
if [[ ! -d "$IPA_APP/Frameworks/CoreCompiler.framework" ]]; then
  echo "missing $IPA_APP/Frameworks/CoreCompiler.framework" >&2
  exit 1
fi

rm -rf "$STAGE" "$APP"
echo "staging compiler frameworks"
mkdir -p "$STAGE/MobileDevelopmentKit.framework/Headers" "$STAGE/MobileDevelopmentKit.framework/Modules" "$APP/Frameworks"

cp "$IPA_APP/Frameworks/MobileDevelopmentKit.framework/MobileDevelopmentKit" "$STAGE/MobileDevelopmentKit.framework/MobileDevelopmentKit"
cp "$IPA_APP/Frameworks/MobileDevelopmentKit.framework/Info.plist" "$STAGE/MobileDevelopmentKit.framework/Info.plist"
cp -R "$IPA_APP/Frameworks/CoreCompiler.framework" "$STAGE/CoreCompiler.framework"
cp "$HOST/PalmMDK.h" "$STAGE/MobileDevelopmentKit.framework/Headers/PalmMDK.h"

while IFS= read -r header; do
  ln -sf "$header" "$STAGE/MobileDevelopmentKit.framework/Headers/$(basename "$header")"
done < <(find "$ROOT/Frameworks/MobileDevelopmentKit" -name '*.h' -print)

cat > "$STAGE/MobileDevelopmentKit.framework/Modules/module.modulemap" <<'EOF'
framework module MobileDevelopmentKit {
  umbrella header "PalmMDK.h"
  export *
}
EOF

OBJ="$HOST/build/obj"
mkdir -p "$OBJ"
CFLAGS=(-target arm64-apple-ios18.0 -isysroot "$SDK" -I "$ROOT/Nyxian" -fobjc-arc)
clang "${CFLAGS[@]}" -DHOST_ENV -I "$ROOT" -I "$HOST/build/procobj/include" -c "$ROOT/Nyxian/LindChain/ProcEnvironment/Surface/trust/signing.c" -o "$OBJ/signing.o"
clang "${CFLAGS[@]}" -c "$ROOT/Nyxian/LindChain/ProcEnvironment/Surface/trust/cdhash.c" -o "$OBJ/cdhash.o"
clang "${CFLAGS[@]}" -c "$HOST/MachOMap.c" -o "$OBJ/MachOMap.o"
clang "${CFLAGS[@]}" -I "$ROOT" -I "$ROOT/LiveProcess" -c "$ROOT/Nyxian/LindChain/PalmHost/PalmLaunch.m" -o "$OBJ/PalmLaunch.o"
clang "${CFLAGS[@]}" -F "$STAGE" -c "$HOST/PalmJobs.m" -o "$OBJ/PalmJobs.o"

PROC="$HOST/build/procobj"
mkdir -p "$PROC"
clang "${CFLAGS[@]}" -I "$ROOT" -I "$ROOT/LiveProcess" -c "$ROOT/Nyxian/LindChain/ProcEnvironment/PEProcess.m" -o "$PROC/PEProcess.m.o"
clang "${CFLAGS[@]}" -I "$ROOT" -I "$ROOT/LiveProcess" -c "$ROOT/Nyxian/LindChain/WindowServer/NXWindowServer.m" -o "$PROC/NXWindowServer.m.o"
clang "${CFLAGS[@]}" -I "$ROOT" -I "$ROOT/LiveProcess" -c "$ROOT/Nyxian/LindChain/WindowServer/Window/NXWindow.m" -o "$PROC/NXWindow.m.o"
clang "${CFLAGS[@]}" -I "$ROOT" -I "$ROOT/LiveProcess" -c "$ROOT/Nyxian/LindChain/ProcEnvironment/Surface/sys/compat/pectl.m" -o "$PROC/pectl.m.o"
clang "${CFLAGS[@]}" -I "$ROOT" -I "$ROOT/LiveProcess" -c "$ROOT/Nyxian/LindChain/WindowServer/Session/NXWindowSessionApplication.m" -o "$PROC/NXWindowSessionApplication.m.o"
proc_args=()
if [[ -d "$PROC" ]]; then
  while IFS= read -r object; do
    case "$(basename "$object")" in
      lookup.c.o|dyld.o) continue ;;
    esac
    proc_args+=("$object")
  done < <(find "$PROC" -name '*.o' -print | sort)
fi

echo "compiling host"
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios18.0 \
  -O \
  -F "$STAGE" \
  -F "$ROOT/Nyxian/LindChain/OpenSSL.xcframework/ios-arm64" \
  -F "$ROOT/Nyxian/LindChain/Private/Frameworks" \
  -framework MobileDevelopmentKit \
  -framework CoreCompiler \
  -framework OpenSSL \
  -framework QuartzCore \
  -framework Security \
  -framework FrontBoard \
  -framework FrontBoardServices \
  -framework RunningBoardServices \
  -framework BoardServices \
  -framework BaseBoard \
  -framework AssertionServices \
  -framework BackBoardServices \
  -larchive \
  -lc++ \
  -import-objc-header "$HOST/Bridging.h" \
  -Xcc -I -Xcc "$ROOT/Nyxian" \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -o "$APP/PalmHost" \
  "$ROOT/Tools/PalmControl/Sources/PalmControl/ControlModel.swift" \
  "$ROOT/Tools/PalmControl/Sources/PalmControl/PbxParser.swift" \
  "$ROOT/Tools/PalmControl/Sources/PalmControl/SDKFrameworks.swift" \
  "$ROOT/Tools/PalmControl/Sources/PalmControl/ProjectDriver.swift" \
  "$ROOT/Tools/PalmControl/Sources/PalmControl/GitPuller.swift" \
  "$ROOT/Tools/PalmControl/Sources/PalmControl/Executor.swift" \
  "$ROOT/Tools/PalmControl/Sources/PalmControl/Signing.swift" \
  "$ROOT/Tools/PalmControl/Sources/PalmControl/Channel.swift" \
  "$ROOT/Nyxian/LindChain/PalmHost/PalmHost.swift" \
  "$HOST/AppMain.swift" \
  "$OBJ/signing.o" \
  "$OBJ/cdhash.o" \
  "$OBJ/PalmLaunch.o" \
  "$OBJ/PalmJobs.o" \
  "${proc_args[@]}"

cp "$HOST/Info.plist" "$APP/Info.plist"
cp -R "$STAGE/MobileDevelopmentKit.framework" "$APP/Frameworks/MobileDevelopmentKit.framework"
cp -R "$STAGE/CoreCompiler.framework" "$APP/Frameworks/CoreCompiler.framework"
cp -R "$ROOT/Nyxian/LindChain/OpenSSL.xcframework/ios-arm64/OpenSSL.framework" "$APP/Frameworks/OpenSSL.framework"
rm -rf "$APP/Frameworks/MobileDevelopmentKit.framework/Headers" "$APP/Frameworks/MobileDevelopmentKit.framework/Modules"
cp "$PROFILE" "$APP/embedded.mobileprovision"

LIVE="${PALM_LIVEPROCESS:-/tmp/palm-liveprocess/Build/LiveProcess.appex}"
if [[ -d "$LIVE" ]]; then
  echo "embedding LiveProcess"
  rm -rf "$APP/PlugIns"
  mkdir -p "$APP/PlugIns"
  cp -R "$LIVE" "$APP/PlugIns/LiveProcess.appex"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.onexengineering.PalmHost.LiveProcess" "$APP/PlugIns/LiveProcess.appex/Info.plist"
  # Liquid glass does not paint inside the hosted scene, so the Allow and Let's Go
  # buttons were invisible. Classic prominent buttons draw in that scene.
  /usr/libexec/PlistBuddy -c "Delete :UIDesignRequiresCompatibility" "$APP/PlugIns/LiveProcess.appex/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :UIDesignRequiresCompatibility bool true" "$APP/PlugIns/LiveProcess.appex/Info.plist"
  # TCC reads the process bundle, which is this appex, not the guest Info.plist.
  LIVE_PLIST="$APP/PlugIns/LiveProcess.appex/Info.plist"
  while IFS='|' read -r key value; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$LIVE_PLIST" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$LIVE_PLIST"
  done <<'EOF'
NSBluetoothAlwaysUsageDescription|The hosted app uses Bluetooth.
NSCalendarsFullAccessUsageDescription|The hosted app uses your calendars.
NSCameraUsageDescription|The hosted app uses the camera.
NSContactsUsageDescription|The hosted app uses your contacts.
NSFaceIDUsageDescription|The hosted app uses Face ID.
NSHealthShareUsageDescription|The hosted app reads health data.
NSHealthUpdateUsageDescription|The hosted app writes health data.
NSLocalNetworkUsageDescription|The hosted app uses the local network.
NSLocationAlwaysAndWhenInUseUsageDescription|The hosted app uses your location.
NSLocationWhenInUseUsageDescription|The hosted app uses your location.
NSMicrophoneUsageDescription|The hosted app uses the microphone.
NSMotionUsageDescription|The hosted app uses motion data.
NSPhotoLibraryAddUsageDescription|The hosted app saves photos.
NSPhotoLibraryUsageDescription|The hosted app uses your photos.
NSSpeechRecognitionUsageDescription|The hosted app uses speech recognition.
EOF
  cp "$PROFILE" "$APP/PlugIns/LiveProcess.appex/embedded.mobileprovision"
  BROAD="${PALM_LIVEPROCESS_DIR:-$(dirname "$LIVE")}/libBroadpatch.dylib"
  if [[ -f "$BROAD" ]]; then
    mkdir -p "$APP/PlugIns/LiveProcess.appex/Frameworks"
    cp "$BROAD" "$APP/PlugIns/LiveProcess.appex/Frameworks/libBroadpatch.dylib"
  fi
fi

echo "signing"
sign() {
  codesign --force --sign "$IDENTITY" --timestamp=none --generate-entitlement-der "$1"
}

while IFS= read -r lib; do
  sign "$lib"
done < <(find "$APP/Frameworks" -type f \( -name '*.dylib' -o -name 'CoreCompiler' -o -name 'MobileDevelopmentKit' \) -print)
sign "$APP/Frameworks/CoreCompiler.framework"
sign "$APP/Frameworks/MobileDevelopmentKit.framework"
sign "$APP/Frameworks/OpenSSL.framework/OpenSSL"
sign "$APP/Frameworks/OpenSSL.framework"
if [[ -d "$APP/PlugIns/LiveProcess.appex" ]]; then
  if [[ -f "$APP/PlugIns/LiveProcess.appex/Frameworks/libBroadpatch.dylib" ]]; then
    sign "$APP/PlugIns/LiveProcess.appex/Frameworks/libBroadpatch.dylib"
  fi
  if [[ -d "$APP/PlugIns/LiveProcess.appex/Frameworks/LiveShim.framework" ]]; then
    sign "$APP/PlugIns/LiveProcess.appex/Frameworks/LiveShim.framework/LiveShim"
    sign "$APP/PlugIns/LiveProcess.appex/Frameworks/LiveShim.framework"
  fi
  codesign --force --sign "$IDENTITY" --timestamp=none --generate-entitlement-der --entitlements "$HOST/LiveProcess.entitlements" "$APP/PlugIns/LiveProcess.appex"
fi
codesign --force --sign "$IDENTITY" --timestamp=none --generate-entitlement-der --entitlements "$HOST/Entitlements.plist" "$APP"
echo "built $APP"
