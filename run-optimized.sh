#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
#
# Fast launch for development.
#
# `./build.sh --dev` repeats work that one edited file cannot affect: the icon
# generator (a `swift` interpreter start), the adaptive icon catalog, the fan
# helper and the Now Playing adapter (five -O files each), the whole bundle
# stage, a signature and a `codesign --verify --deep`. This script keeps its own
# scratch build under build/run/ instead:
#
#   - the app compiles incrementally with the same flags build.sh --dev passes,
#     and is skipped outright when no source is newer than the binary;
#   - the helper, the adapter and the icons rebuild only when their inputs
#     change;
#   - the bundle is staged once, then only its executable is replaced;
#   - the signature uses the same identity preference as build.sh, without the
#     Developer ID timestamp: nothing here is notarized.
#
# The bundle keeps the Developer variant's identity (same name, bundle id and
# Info.plist edits), so it runs beside the official app and keeps its own
# permissions and preferences. Nothing is installed into /Applications.
#
#   ./run-optimized.sh              # build if needed, then launch (detached)
#   ./run-optimized.sh --foreground # launch attached; Ctrl-C quits, logs here
#   ./run-optimized.sh --check      # build, verify the bundle, do not launch
#   ./run-optimized.sh --smoke      # build, run --selftest inside the bundle
#   ./run-optimized.sh --rebuild    # rebuild the app, helper, adapter and icons
#   ./run-optimized.sh --clean      # drop build/run/ and rebuild from scratch
#
# Any other argument is passed to the app.
set -euo pipefail
cd "$(dirname "$0")"

# Mirrors the Developer variant in build.sh. build.sh is the source of truth:
# when a flag, file list or bundle id changes there, change it here too.
APP_NAME="Vorssaint (Developer)"
EXECUTABLE="VorssaintDeveloper"
APP_BUNDLE_ID="com.vorssaint.utils.dev"
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
NOW_PLAYING_ADAPTER_ID="$APP_BUNDLE_ID.now-playing"
NOW_PLAYING_ADAPTER="libVorssaintNowPlaying.dylib"
TARGET="arm64-apple-macosx14.0"
ENTITLEMENTS="Resources/Vorssaint.entitlements"
LEGACY_IDENTITY="Vorssaint Utils Signing"

SCRATCH="build/run"
OBJECT_DIR="$SCRATCH/objects"
STAMPS="$SCRATCH/stamps"
BUNDLE="$SCRATCH/stage.noindex/$APP_NAME.app"
APP_BINARY="$SCRATCH/$EXECUTABLE"
HELPER_BINARY="$SCRATCH/$FAN_HELPER_ID"
ADAPTER_BINARY="$SCRATCH/$NOW_PLAYING_ADAPTER"

CHECK=false
SMOKE=false
REBUILD=false
FOREGROUND=false
APP_ARGS=()

usage() {
    awk '/^# Fast launch/{on=1} /^set -euo/{on=0} on{sub(/^# ?/, ""); print}' "$0"
}

for arg in "$@"; do
    case "$arg" in
        --check)   CHECK=true ;;
        --smoke)   SMOKE=true ;;
        --foreground|--fg) FOREGROUND=true ;;
        --rebuild) REBUILD=true ;;
        --clean)   REBUILD=true; rm -rf "$SCRATCH" ;;
        --help|-h) usage; exit 0 ;;
        *)         APP_ARGS+=("$arg") ;;
    esac
done

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found on PATH" >&2; exit 1; }
command -v codesign >/dev/null 2>&1 || { echo "error: codesign not found on PATH" >&2; exit 1; }

# Same SDK selection as build.sh: the macOS 26 SDK when it is installed, because
# the 27 SDK turns SwiftUI property wrappers into macros whose plugin the
# Command Line Tools cannot load.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

mkdir -p "$OBJECT_DIR" "$STAMPS"

# A content hash over every input, so a stamp survives checkouts, touches and
# clock changes: only real edits rebuild.
tree_hash() {
    find "$@" -type f -print0 | sort -z \
        | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}'
}

stamp_ok() {
    local stamp_name="$1" want="$2" file="$STAMPS/$1"
    [[ "$REBUILD" = false && -f "$file" && "$(cat "$file")" == "$want" ]]
}

write_stamp() {
    printf '%s\n' "$2" > "$STAMPS/$1"
}

# build.sh's output file map, in bash: one object and one swiftdeps file per
# source, plus the master record the incremental engine reads back.
write_output_file_map() {
    local output_file="$1" object_dir="$2"
    shift 2
    local source artifact first=1
    {
        printf '{\n'
        printf '  "": {\n'
        printf '    "swift-dependencies": "%s/master.swiftdeps"\n' "$object_dir"
        printf '  }'
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            printf ',\n'
            printf '  "%s": {\n' "$source"
            printf '    "object": "%s/%s.o",\n' "$object_dir" "$artifact"
            printf '    "swift-dependencies": "%s/%s.swiftdeps"\n' "$object_dir" "$artifact"
            printf '  }'
            first=0
        done
        printf '\n}\n'
    } > "$output_file"
}

# --- icons -------------------------------------------------------------------

ICON_HASH="$(tree_hash Tools/MakeIcon.swift Resources/Brand)"
if stamp_ok icons "$ICON_HASH" \
        && [[ -f build/AppIcon.icns && -f build/MenuBarIcon.png && -f build/BrandMark.png ]]; then
    :
else
    echo "▸ Generating icons…" >&2
    swift Tools/MakeIcon.swift build/AppIcon.iconset
    xattr -c -r build/AppIcon.iconset build/AppIcon.icns \
        build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
    write_stamp icons "$ICON_HASH"
fi

# The adaptive catalog needs full Xcode 26+, so its absence is not an error: the
# Dock falls back to AppIcon.icns, exactly as build.sh reports it.
CATALOG_HASH="$(tree_hash Resources/Brand/AppIcon.icon 2>/dev/null || echo none)"
if stamp_ok catalog "$CATALOG_HASH" && [[ -f build/Assets.car ]]; then
    :
else
    ACTOOL_BIN="$(xcrun --find actool 2>/dev/null || true)"
    if [[ -n "$ACTOOL_BIN" ]]; then
        echo "▸ Compiling adaptive icon catalog…" >&2
        ICON_TMP="$(mktemp -d)"
        trap 'rm -rf "$ICON_TMP"' EXIT
        ditto "Resources/Brand/AppIcon.icon" "$ICON_TMP/AppIcon.icon"
        mkdir -p "$ICON_TMP/catalog"
        if "$ACTOOL_BIN" "$ICON_TMP/AppIcon.icon" \
                --compile "$ICON_TMP/catalog" \
                --app-icon AppIcon \
                --platform macosx \
                --target-device mac \
                --minimum-deployment-target 14.0 \
                --enable-on-demand-resources NO \
                --output-partial-info-plist "$ICON_TMP/partial-info.plist" \
                >"$ICON_TMP/actool.log" 2>&1 && [[ -s "$ICON_TMP/catalog/Assets.car" ]]; then
            mv "$ICON_TMP/catalog/Assets.car" build/Assets.car
            write_stamp catalog "$CATALOG_HASH"
        else
            echo "  adaptive icon skipped: actool could not compile the catalog" >&2
            rm -f build/Assets.car
            write_stamp catalog "$CATALOG_HASH"
        fi
        rm -rf "$ICON_TMP"
        trap - EXIT
    else
        echo "  adaptive icon skipped: actool not found (needs Xcode 26+)" >&2
        write_stamp catalog "$CATALOG_HASH"
    fi
fi

# --- fan helper --------------------------------------------------------------

HELPER_SOURCES=(
    Sources/Vorssaint/Services/FanControl/FanControlSupport.swift
    Sources/Vorssaint/Services/FanControl/FanControlXPC.swift
    Sources/Vorssaint/Services/SystemMonitor/SMCClient.swift
    Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift
    Sources/Vorssaint/Services/FanControl/FanControlHardware.swift
    Sources/FanControlHelper/main.swift
)
HELPER_HASH="$(tree_hash "${HELPER_SOURCES[@]}")"
if stamp_ok helper "$HELPER_HASH" && [[ -x "$HELPER_BINARY" ]]; then
    :
else
    echo "▸ Compiling protected fan helper…" >&2
    swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" -D VORSSAINT_DEVELOPMENT \
        "${HELPER_SOURCES[@]}" -o "$HELPER_BINARY"
    "$HELPER_BINARY" --selftest
    write_stamp helper "$HELPER_HASH"
fi

# --- Now Playing adapter -----------------------------------------------------

ADAPTER_SOURCES=(
    Sources/NowPlayingAdapter/NowPlayingAdapter.swift
    Sources/NowPlayingAdapter/NowPlayingQueue.swift
    Sources/NowPlayingAdapter/NowPlayingSelection.swift
    Sources/Vorssaint/Services/Notch/NotchPlaybackSource.swift
    Sources/Vorssaint/Services/Notch/NotchPlaybackCommand.swift
)
ADAPTER_HASH="$(tree_hash "${ADAPTER_SOURCES[@]}")"
if stamp_ok adapter "$ADAPTER_HASH" && [[ -f "$ADAPTER_BINARY" ]]; then
    :
else
    echo "▸ Compiling Now Playing adapter…" >&2
    swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" -emit-library \
        -module-name VorssaintNowPlaying "${ADAPTER_SOURCES[@]}" -o "$ADAPTER_BINARY"
    write_stamp adapter "$ADAPTER_HASH"
fi

# --- app ---------------------------------------------------------------------

APP_SOURCES=()
while IFS= read -r source; do
    APP_SOURCES+=("$source")
done < <(find Sources/Vorssaint -name '*.swift' | sort)

APP_FLAGS="-Onone -D VORSSAINT_DEVELOPMENT $TARGET $SDK ${SDK_COMPAT_FLAGS[*]-}"
APP_HASH="$(printf '%s\n%s\n' "$APP_FLAGS" "${APP_SOURCES[*]}" | shasum -a 256 | awk '{print $1}')"

# swiftc would skip unchanged files on its own, but it still links the app and
# re-reads the module graph. A source newer than the binary is the only thing
# that can make the output stale, so ask that first and skip the driver whole.
if stamp_ok app "$APP_HASH" && [[ -f "$APP_BINARY" ]] \
        && [[ -z "$(find Sources/Vorssaint -name '*.swift' -newer "$APP_BINARY" -print -quit)" ]]; then
    echo "▸ App is up to date." >&2
else
    echo "▸ Compiling (debug) against $(basename "$SDK")…" >&2
    write_output_file_map "$OBJECT_DIR/output-file-map.json" "$OBJECT_DIR" "${APP_SOURCES[@]}"
    swiftc -Onone -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
        -output-file-map "$OBJECT_DIR/output-file-map.json" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        -I Sources/VMStatisticsCompat -I Sources/HIDEventSystem \
        -D VORSSAINT_DEVELOPMENT \
        "${APP_SOURCES[@]}" -o "$APP_BINARY"
    write_stamp app "$APP_HASH"
fi

# --- bundle ------------------------------------------------------------------

RESOURCE_HASH="$(tree_hash Resources CHANGELOG.md build/AppIcon.icns \
    build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || echo none)"

if stamp_ok stage "$RESOURCE_HASH" && [[ -d "$BUNDLE" ]]; then
    echo "▸ Refreshing the staged bundle…" >&2
    cp "$APP_BINARY" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
    [[ -x "$HELPER_BINARY" ]] && cp "$HELPER_BINARY" \
        "$BUNDLE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    [[ -f "$ADAPTER_BINARY" ]] && cp "$ADAPTER_BINARY" \
        "$BUNDLE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
else
    echo "▸ Staging the bundle…" >&2
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" \
        "$BUNDLE/Contents/Library/LaunchDaemons" "$BUNDLE/Contents/Library/LaunchServices" \
        "$BUNDLE/Contents/Frameworks"
    cp "$APP_BINARY" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
    cp "$HELPER_BINARY" "$BUNDLE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    cp "$ADAPTER_BINARY" "$BUNDLE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
    cp Resources/now-playing.pl Resources/agent-prices.json "$BUNDLE/Contents/Resources/"
    cp Resources/com.vorssaint.utils.fan-control.plist \
        "$BUNDLE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
    cp CHANGELOG.md "$BUNDLE/Contents/Resources/CHANGELOG.md"
    for lproj in Resources/*.lproj; do
        cp -R "$lproj" "$BUNDLE/Contents/Resources/"
    done
    # The Developer variant's own identity, so it installs and runs beside the
    # official app with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$BUNDLE/Contents/Info.plist"
    FAN_PLIST="$BUNDLE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.vorssaint.utils.fan-control" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    FAN_HELPER_VERSION="$(
        export LC_ALL=C
        /usr/bin/shasum -a 256 \
            "$BUNDLE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
            "$FAN_PLIST" \
            | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
            | /usr/bin/awk '{print $1}'
    )"
    /usr/libexec/PlistBuddy -c "Add :VorssaintFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
        "$BUNDLE/Contents/Info.plist"
    printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
    cp build/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
    cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$BUNDLE/Contents/Resources/"
    [[ -f build/Assets.car ]] && cp build/Assets.car "$BUNDLE/Contents/Resources/Assets.car"
    if [[ -d Resources/Gifs ]]; then
        mkdir -p "$BUNDLE/Contents/Resources/Gifs"
        cp Resources/Gifs/*.gif "$BUNDLE/Contents/Resources/Gifs/"
    fi
    if [[ -d Resources/Images ]]; then
        mkdir -p "$BUNDLE/Contents/Resources/Images"
        cp Resources/Images/* "$BUNDLE/Contents/Resources/Images/"
    fi
    xattr -c -r "$BUNDLE" 2>/dev/null || true
    write_stamp stage "$RESOURCE_HASH"
fi

# Stamp the source commit and build time so the running app shows, in About,
# exactly which code it came from. Dev-only; never shipped.
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
if /usr/libexec/PlistBuddy -c "Print :VorssaintBuildCommit" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :VorssaintBuildCommit $SHA · $(date '+%Y-%m-%d %H:%M')" \
        "$BUNDLE/Contents/Info.plist"
else
    /usr/libexec/PlistBuddy -c "Add :VorssaintBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" \
        "$BUNDLE/Contents/Info.plist"
fi

# --- signature ---------------------------------------------------------------

# Same preference order as build.sh, minus the timestamp: a Developer ID build
# here is for running locally, never for notarization, and the timestamp round
# trip is the slowest part of signing.
DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"

legacy_identity_can_sign() {
    local probe signed=1
    # Locked after every reboot, and a locked keychain cannot sign.
    security unlock-keychain -p vorssaint-signing \
        "$HOME/Library/Keychains/vorssaint-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$probe" \
        >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

if [[ -n "$DEVID" ]]; then
    SIGN_IDENTITY="$DEVID"
    SIGN_KIND="Developer ID"
elif legacy_identity_can_sign; then
    SIGN_IDENTITY="$LEGACY_IDENTITY"
    SIGN_KIND="local identity"
else
    SIGN_IDENTITY="-"
    SIGN_KIND="ad-hoc"
fi

echo "▸ Signing ($SIGN_KIND)…" >&2
sign_target() {
    local target="$1"
    shift
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$@" "$target"
    elif [[ -n "$DEVID" ]]; then
        /usr/bin/codesign --force --strip-disallowed-xattrs --options runtime \
            --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$@" "$target"
    else
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$SIGN_IDENTITY" "$@" "$target"
    fi
}

[[ -f "$BUNDLE/Contents/Library/LaunchServices/$FAN_HELPER_ID" ]] \
    && sign_target "$BUNDLE/Contents/Library/LaunchServices/$FAN_HELPER_ID" --identifier "$FAN_HELPER_ID"
[[ -f "$BUNDLE/Contents/Frameworks/$NOW_PLAYING_ADAPTER" ]] \
    && sign_target "$BUNDLE/Contents/Frameworks/$NOW_PLAYING_ADAPTER" --identifier "$NOW_PLAYING_ADAPTER_ID"
sign_target "$BUNDLE"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "  ad-hoc: every rebuild is a new identity, so Accessibility and Screen" >&2
    echo "  Recording grants reset. Run ./Tools/setup-signing.sh once for a stable one." >&2
fi

# --- run ---------------------------------------------------------------------

if [[ "$CHECK" = true ]]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$BUNDLE/Contents/Info.plist")"
    [[ "$bundle_id" == "$APP_BUNDLE_ID" ]] || {
        echo "error: bundle id is $bundle_id, expected $APP_BUNDLE_ID" >&2; exit 1; }
    [[ -x "$BUNDLE/Contents/MacOS/$EXECUTABLE" ]] || {
        echo "error: missing executable in $BUNDLE" >&2; exit 1; }
    /usr/bin/codesign --verify --deep --strict "$BUNDLE" || {
        echo "error: signature does not verify" >&2; exit 1; }
    echo "✓ Bundle OK: $BUNDLE" >&2
    exit 0
fi

stop_running() {
    pkill -x "$EXECUTABLE" 2>/dev/null || return 0
    for _ in $(seq 1 50); do
        pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    echo "  $EXECUTABLE is still running; it may refuse to quit" >&2
}

if [[ "$SMOKE" = true ]]; then
    echo "▸ Running --selftest…" >&2
    # Executed from inside the bundle, so Bundle.main is the app and every
    # resource lookup behaves as it does when launched normally.
    set +e
    "$BUNDLE/Contents/MacOS/$EXECUTABLE" --selftest
    status=$?
    set -e
    echo "✓ selftest exited $status" >&2
    exit "$status"
fi

stop_running
# Braced: bash 3.2 reads the ellipsis's bytes as part of the name under a UTF-8
# locale, and the launch dies on an unbound variable after signing.
if [[ "$FOREGROUND" = true ]]; then
    # Attached, the way run.sh behaves for the single-file apps: the terminal
    # holds the process, stderr lands here, and Ctrl-C quits. Executed from
    # inside the bundle, so Bundle.main is still the app. A feature that needs a
    # usage description can be refused when the launching terminal has none, so
    # fall back to the detached launch when something misbehaves only here.
    echo "▸ Running ${APP_NAME} (Ctrl-C quits)…" >&2
    if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
        exec "$BUNDLE/Contents/MacOS/$EXECUTABLE" "${APP_ARGS[@]}"
    else
        exec "$BUNDLE/Contents/MacOS/$EXECUTABLE"
    fi
fi

echo "▸ Launching ${APP_NAME}…" >&2
if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
    open -n "$BUNDLE" --args "${APP_ARGS[@]}"
else
    open -n "$BUNDLE"
fi
echo "  Running as a background app; quit it from its menu bar item." >&2
