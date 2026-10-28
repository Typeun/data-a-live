#!/bin/bash
# Build pandora-hello with the NDK's LLVM tools: out/Image and out/hello-boot.img.
set -euo pipefail
cd "$(dirname "$0")"
# NDK location and host tag: windows-x86_64 on Git Bash, linux-x86_64 inside the VM.
NDK=${ANDROID_NDK_HOME:-${NDK:-}}
for c in "$NDK" "$PWD"/../../../../../tools/ndk/* "$PWD"/../../../../tools/ndk/* \
	"$HOME/Android/Sdk/ndk"/* /opt/android-ndk* /d/Android/ndk/*; do
	[ -n "$c" ] || continue
	if ls "$c"/toolchains/llvm/prebuilt/*/bin/clang* >/dev/null 2>&1; then NDK=$c; break; fi
done
[ -n "$NDK" ] || { echo "no Android NDK found (set ANDROID_NDK_HOME)" >&2; exit 1; }

PY=
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || { echo "needs python3" >&2; exit 1; }
HOSTTAG=${HOSTTAG:-windows-x86_64}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
T="$NDK/toolchains/llvm/prebuilt/$HOSTTAG/bin"
out=out
mkdir -p $out
tmpdir=$PWD/$out/.tmp
mkdir -p "$tmpdir"
# native clang needs a Windows path; /c/... is refused with "unable to make temporary file"
if command -v cygpath >/dev/null 2>&1; then tmpdir=$(cygpath -w "$tmpdir"); fi
export TMPDIR="$tmpdir" TMP="$tmpdir" TEMP="$tmpdir"
flags=(--target=aarch64-none-elf -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic
       -fno-stack-protector -mgeneral-regs-only -mstrict-align -Wall -Wextra -Werror)
"$T/clang$EXE" "${flags[@]}" -c start.S -o $out/start.o
"$T/clang$EXE" "${flags[@]}" -c hello.c -o $out/hello.o
# Loaded at an unknown address: refuse absolute relocations in C.
if "$T/llvm-readelf$EXE" -r $out/hello.o | grep -q R_AARCH64_ABS; then
	echo "absolute relocation in hello.c" >&2; exit 1
fi
"$T/ld.lld$EXE" -T hello.ld --build-id=none $out/start.o $out/hello.o -o $out/hello.elf
"$T/llvm-objcopy$EXE" -O binary $out/hello.elf $out/Image
"$PY" -I ../../tools/mkbootimg_v4.py $out/Image $out/hello-boot.img
python -I ../../tools/bootimg_info.py $out/hello-boot.img
sha256sum $out/hello-boot.img
