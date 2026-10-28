#!/bin/bash
# Build the myron iOS root image from an iPhone X (D22AP) iOS 16.7.16 IPSW.
#
#   tools/mkroot_myron.sh IPSW_OR_URL OUT.img [SIZE] [--extract-only]
#
# IPSW_OR_URL   local .ipsw, or an https URL (only the three members are fetched)
# SIZE          16G / 16384M / 16 (GiB default 16)
# --extract-only  stop after unpacking the three dmg files (works on any OS)
#
# The IPSW's three disk images are read straight out of the zip, then
# tools/mkiosroot.sh turns them into one case-sensitive journaled HFS+ volume and
# tools/sweet-root-tweaks.py applies the userland changes (both from dipa-studio/ios-sweet,
# MIT). Needs for the full build: apfs-fuse, hfsprogs, rsync, python3, sudo, Linux.
#
# Component names are the ones in this IPSW's BuildManifest.plist (verified 2026-10-28):
#   OS               -> 087-86698-044.dmg
#   Cryptex1,SystemOS-> 087-86593-047.dmg
#   Cryptex1,AppOS   -> 087-86715-047.dmg
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# python3 when it works, else python (Git Bash ships the former as a store stub)
PY=
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then
		PY=$c
		break
	fi
done
[ -n "$PY" ] || { echo "needs python3" >&2; exit 1; }

usage() { sed -n '2,17p' "$0"; exit 2; }

EXTRACT_ONLY=0
ARGS=()
for a in "$@"; do
	case $a in
	--extract-only) EXTRACT_ONLY=1 ;;
	-h|--help) usage ;;
	*) ARGS+=("$a") ;;
	esac
done
[ "${#ARGS[@]}" -ge 2 ] || usage
SRC=${ARGS[0]} OUT=${ARGS[1]} SIZE=${ARGS[2]:-16G}

OS_DMG=${OS_DMG:-087-86698-044.dmg}
SYSOS_DMG=${SYSOS_DMG:-087-86593-047.dmg}
APPOS_DMG=${APPOS_DMG:-087-86715-047.dmg}

case $SIZE in
*G|*g) size_mb=$(( ${SIZE%[Gg]} * 1024 )) ;;
*M|*m) size_mb=${SIZE%[Mm]} ;;
*[0-9]) size_mb=$(( SIZE * 1024 )) ;;
*) echo "bad SIZE '$SIZE' (16G, 16384M or 16)" >&2; exit 2 ;;
esac
[ "$size_mb" -ge 4096 ] || { echo "SIZE must be at least 4 GiB" >&2; exit 2; }

if [ "$EXTRACT_ONLY" = 0 ]; then
	[[ ! -e $OUT ]] || { echo "refusing to overwrite $OUT" >&2; exit 1; }
	for tool in apfs-fuse mkfs.hfsplus rsync sudo; do
		command -v "$tool" >/dev/null 2>&1 ||
			{ echo "missing $tool (apt install apfs-fuse hfsprogs rsync)" >&2; exit 1; }
	done
fi

# the image plus the three dmgs (about 8 GB) plus slack
if [ "$EXTRACT_ONLY" = 0 ]; then
	need_mb=$(( size_mb + 10240 ))
	avail_mb=$(df -Pm "$(dirname "$OUT")" | awk 'NR==2 {print $4}')
	if [ "${avail_mb:-0}" -lt "$need_mb" ]; then
		echo "need ${need_mb} MiB free for ${OUT} and the dmgs, have ${avail_mb} MiB" >&2
		exit 1
	fi
fi

if [ "$EXTRACT_ONLY" = 1 ]; then
	work=${WORKDIR:-$PWD/ipsw-extract}
	mkdir -p "$work"
	mnt=""
else
	work=$(mktemp -d)
	mnt=$(mktemp -d)
fi

cleanup() {
	[ -n "${mnt:-}" ] && mountpoint -q "$mnt" && sudo umount "$mnt" || true
	[ "$EXTRACT_ONLY" = 1 ] || rm -rf "$work" "$mnt"
}
trap cleanup EXIT

echo "== 1. extract the three disk images into $work"
t0=$(date +%s)
if [[ $SRC =~ ^https?:// ]]; then
	"$PY" "$ROOT/tools/fetch-ipsw-member.py" "$SRC" "$OS_DMG"    "$work/OS.dmg"
	"$PY" "$ROOT/tools/fetch-ipsw-member.py" "$SRC" "$SYSOS_DMG" "$work/SystemOS.dmg"
	"$PY" "$ROOT/tools/fetch-ipsw-member.py" "$SRC" "$APPOS_DMG" "$work/AppOS.dmg"
else
	"$PY" - "$SRC" "$work" "$OS_DMG" "$SYSOS_DMG" "$APPOS_DMG" <<'PY'
import shutil, sys, zipfile
src, out, os_dmg, sysos_dmg, appos_dmg = sys.argv[1:6]
names = {os_dmg: 'OS.dmg', sysos_dmg: 'SystemOS.dmg', appos_dmg: 'AppOS.dmg'}
with zipfile.ZipFile(src) as z:
    have = set(z.namelist())
    for member, name in names.items():
        if member not in have:
            sys.exit('missing %s in %s' % (member, src))
        with z.open(member) as f, open(out + '/' + name, 'wb') as g:
            shutil.copyfileobj(f, g, 1 << 20)
        print('  %-20s <- %s' % (name, member))
PY
fi
echo "   took $(( $(date +%s) - t0 ))s"
ls -l "$work"/*.dmg

if [ "$EXTRACT_ONLY" = 1 ]; then
	echo "== extracted only (no image built)"
	exit 0
fi

echo "== 2. HFS+ root image ($SIZE = ${size_mb} MiB)"
t0=$(date +%s)
sudo bash "$ROOT/tools/mkiosroot.sh" "$work/OS.dmg" "$work/SystemOS.dmg" "$work/AppOS.dmg" "$OUT" "$SIZE"

echo "== 3. userland tweaks"
sudo fsck.hfsplus -fy "$OUT" >/dev/null 2>&1 || true
sudo mount -t hfsplus -o loop,force "$OUT" "$mnt"
sudo "$PY" "$ROOT/tools/sweet-root-tweaks.py" "$mnt"
sudo umount "$mnt"

echo "== done in $(( $(date +%s) - t0 ))s (stage 2+3)"
ls -l "$OUT"
sha256sum "$OUT"
echo "next:"
echo "  tools/pinfile-build.sh --push"
echo "  adb shell su -c '/data/local/tmp/pinfile create /data/local/tmp/iosroot.img $size_mb'"
echo "  adb exec-in \"su -c '/data/local/tmp/pinfile rawwrite /data/local/tmp/iosroot.img /dev/block/by-name/userdata $(( size_mb * 256 )) --yes'\" < $OUT"
