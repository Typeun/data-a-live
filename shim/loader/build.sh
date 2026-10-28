#!/bin/bash
# Build pandora-loader with the NDK's LLVM tools: out/Image and out/loader-boot.img.
# Needs out/payload.bin from wsl/make_phone_payload.sh. OUT=dir builds from dir/payload.bin instead.
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
HOSTTAG=${HOSTTAG:-windows-x86_64}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
T="$NDK/toolchains/llvm/prebuilt/$HOSTTAG/bin"
out=${OUT:-out}
mkdir -p $out
# clang writes temporaries; the default TMP is read-only in some sandboxes
mkdir -p "$out/.tmp"
tmpdir=$PWD/$out/.tmp
# native clang needs a Windows path; /c/... is refused with "unable to make temporary file"
if command -v cygpath >/dev/null 2>&1; then tmpdir=$(cygpath -w "$tmpdir"); fi
export TMPDIR="$tmpdir" TMP="$tmpdir" TEMP="$tmpdir"
[ -f $out/payload.bin ] || { echo "missing $out/payload.bin (wsl/make_phone_payload.sh)" >&2; exit 1; }
# The boot logo (tools/bootlogo.py, from the user's IPSW): none is a black screen.
[ -f $out/logo.bin ] || : > $out/logo.bin
flags=(--target=aarch64-none-elf -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic
       -fno-stack-protector -mgeneral-regs-only -mstrict-align -Wall -Wextra -Werror)
"$T/clang$EXE" "${flags[@]}" -c start.S -o $out/start.o
"$T/clang$EXE" "${flags[@]}" -DPAYLOAD=\"$out/payload.bin\" -c payload.S -o $out/payload.o
"$T/clang$EXE" "${flags[@]}" -DLOGO=\"$out/logo.bin\" -c logo.S -o $out/logo.o
"$T/clang$EXE" "${flags[@]}" -c loader.c -o $out/loader.o
# Loaded at an unknown address: refuse absolute relocations in C.
if "$T/llvm-readelf$EXE" -r $out/loader.o | grep -q R_AARCH64_ABS; then
	echo "absolute relocation in loader.c" >&2; exit 1
fi
"$T/ld.lld$EXE" -T loader.ld --build-id=none $out/start.o $out/loader.o $out/logo.o $out/payload.o -o $out/loader.elf
"$T/llvm-objcopy$EXE" -O binary $out/loader.elf $out/Image
# The header's image_size must cover the whole file, payload included.
python -I - $out/Image $out/payload.bin <<'PY'
import struct, sys
img = open(sys.argv[1], 'rb').read(); pl = open(sys.argv[2], 'rb').read()
size = struct.unpack_from('<Q', img, 16)[0]
assert img[0x38:0x3c] == b'ARM\x64', 'no arm64 Image magic'
assert size == len(img), (hex(size), hex(len(img)))
off = img.find(pl[:64])
assert off > 0 and off % 4096 == 0 and img[off:off + len(pl)] == pl, 'payload not embedded'
print('Image %d bytes, payload at 0x%x (%d bytes)' % (len(img), off, len(pl)))
PY
python -I ../../tools/mkbootimg_v4.py $out/Image $out/loader-boot.img
python -I ../../tools/bootimg_info.py $out/loader-boot.img
sha256sum $out/loader-boot.img
