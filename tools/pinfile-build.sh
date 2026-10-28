#!/bin/bash
# Build tools/pinfile for the phone and push it. The only build dependency of the whole port.
#
#   tools/pinfile-build.sh [--push]
#
# Needs an Android NDK (r26+). Looked up in this order:
#   $ANDROID_NDK_HOME, $NDK, <repo>/.ndk/*, <repo>/../tools/ndk/*, ~/Android/Sdk/ndk/*,
#   /opt/android-ndk*, D:/Android/ndk/*
# The host tag is detected from uname (linux-x86_64 / darwin-x86_64 / windows-x86_64).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}
DEVICE=${DEVICE:-myron}
PUSH=0
[ "${1:-}" = "--push" ] && PUSH=1

say() { printf '%s\n' "$*"; }

# --- find the NDK -----------------------------------------------------------
candidates=()
[ -n "${ANDROID_NDK_HOME:-}" ] && candidates+=("$ANDROID_NDK_HOME")
[ -n "${NDK:-}" ] && candidates+=("$NDK")
for d in "$ROOT"/.ndk/* "$ROOT"/ndk/* "$ROOT"/../tools/ndk/* "$ROOT"/../../../tools/ndk/* \
	"$HOME/Android/Sdk/ndk"/* /opt/android-ndk* /opt/android-sdk/ndk/* "/d/Android/ndk"/*; do
	[ -d "$d" ] && candidates+=("$d")
done
NDK_DIR=""
for d in "${candidates[@]}"; do
	if [ -x "$d/toolchains/llvm/prebuilt"/*/bin/clang ] || ls "$d"/toolchains/llvm/prebuilt/*/bin/clang* >/dev/null 2>&1; then
		NDK_DIR=$d
		break
	fi
done
[ -n "$NDK_DIR" ] || {
	say "no Android NDK found. Set ANDROID_NDK_HOME, or install one:"
	say "  Linux : sdkmanager --install 'ndk;27.2.12479018'"
	say "  macOS : brew install --cask android-ndk"
	say "  any   : https://developer.android.com/ndk/downloads (about 700 MB)"
	exit 1
}
say "NDK: $NDK_DIR"

case "$(uname -s)" in
Darwin) HOST=darwin-x86_64 ;;
MINGW*|MSYS*|CYGWIN*) HOST=windows-x86_64 ;;
*) HOST=linux-x86_64 ;;
esac
CC="$NDK_DIR/toolchains/llvm/prebuilt/$HOST/bin/clang"
[ -x "$CC" ] || CC="$CC.exe"
[ -x "$CC" ] || { say "clang not found under $NDK_DIR for host $HOST"; exit 1; }

# --- build ------------------------------------------------------------------
# clang needs a writable temp dir; the default TMPDIR can be read-only in sandboxes
tmpdir="$ROOT/device/.tmp"
mkdir -p "$tmpdir"
# native clang needs a Windows path; /c/... is refused with "unable to make temporary file"
if command -v cygpath >/dev/null 2>&1; then tmpdir=$(cygpath -w "$tmpdir"); fi
export TMPDIR="$tmpdir" TMP="$tmpdir" TEMP="$tmpdir"

out="$ROOT/device/pinfile"
mkdir -p "$(dirname "$out")"
say "building $(basename "$out") for aarch64-linux-android30"
"$CC" --target=aarch64-linux-android30 -static -O2 -Wall -Wextra -Werror \
	"$ROOT/tools/pinfile/pinfile.c" -o "$out"
[ -f "$out" ] || { say "build failed"; exit 1; }
say "built: $(wc -c < "$out") bytes"

# --- verify -----------------------------------------------------------------
if command -v file >/dev/null 2>&1; then
	file "$out"
fi
if command -v readelf >/dev/null 2>&1; then
	readelf -h "$out" | grep -E 'Class|Machine|Type' || true
fi

# --- push -------------------------------------------------------------------
if [ "$PUSH" = 1 ]; then
	[ "$("$ADB" shell getprop ro.product.device | tr -d '\r')" = "$DEVICE" ] || {
		say "no $DEVICE on adb"; exit 1; }
	# Git Bash converts /data/... into C:/Program Files/Git/data/..., so hand adb a
	# Windows-form source and switch the conversion off for the remote path.
	if command -v cygpath >/dev/null 2>&1; then src=$(cygpath -w "$out"); else src=$out; fi
	MSYS_NO_PATHCONV=1 "$ADB" push "$src" /data/local/tmp/pinfile
	"$ADB" shell su -c "chmod 755 /data/local/tmp/pinfile"
	say "pushed: /data/local/tmp/pinfile"
	say "check: adb shell su -c '/data/local/tmp/pinfile status /data/local/tmp/iosroot.img'"
else
	say ""
	say "next:"
	say "  $0 --push"
	say "  # or: adb push $out /data/local/tmp/pinfile && adb shell su -c 'chmod 755 /data/local/tmp/pinfile'"
fi
