#!/bin/bash
# make_phone_payload.sh RUNDIR [extra cmdline]: phone ADT + payload for shim/loader -> shim/loader/out/payload.bin
# ADTFLAGS=--qemu-gic NAME=outq: QEMU-GIC variant for tools/qemu_loader.py into shim/loader/outq/
# CPUS=N: cores to start (default 1); DEBUG=0x8: panics restart (0xc waits, DB_NMI)
# KERNEL=FILE: this kernel instead of RUNDIR's (e.g. tools/mkprelink.py output with original kexts)
# LOGO=FILE: the boot logo image (default the IPSW's applelogo in /opt/work/ipsw/logo)
# RD=ufsroot0: root on UFS (with ADTFLAGS --root-extents for a pinned userdata file), no RAM
#   disk; default RD=md0 with the sweet-init RAM disk
# TRUSTCACHE="FILE..." : IPSW trust caches (first = static) into the payload and the ADT
#   (tools/addtrustcache.py), e.g. /opt/work/ipsw/Firmware/087-86698-044.dmg.trustcache
set -e
R=$1; EXTRA=${2:-}; N=${NAME:-out}; CPUS=${CPUS:-1}; RD=${RD:-md0}; DEBUG=${DEBUG:-0xc}
RAMDISK=()
if [ "$RD" = md0 ]; then
	INIT=${INIT:-$SRC/init/sweet-init}
	[ -f "$INIT" ] || {
		echo "md0 root needs a ramdisk: build ios-sweet's tools/sweet-init.S and pass INIT=..." >&2
		echo "  (or use --rd ufsroot0 to boot the pinned root image directly)" >&2
		exit 1
	}
	RAMDISK=(--ramdisk "$INIT")
fi
# Source tree and scratch copy: set SRC/T, otherwise the repo this script lives in and a temp dir.
SRC=${SRC:-$(cd "$(dirname "$0")/.." && pwd)}; T=${T:-/tmp/myron-tools}; mkdir -p $T
# python3 when it works, else python (Git Bash ships the former as a store stub)
PY=
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then
		PY=$c
		break
	fi
done
[ -n "$PY" ] || { echo "needs python3" >&2; exit 1; }
for f in adt.py mkpayload.py; do tr -d '\r' < $SRC/tools/$f > $T/$f; done
tr -d '\r' < $SRC/tools/mkadt_pandora.py > $T/mkadt_pandora.py
tr -d '\r' < $SRC/tools/addtrustcache.py > $T/addtrustcache.py
# Kernel VA that maps to phys_base: 32 MB below the lowest segment instead of the mach header,
# so original kexts that tools/mkprelink.py placed below our kernel are copied too (same value
# as before for a kernel without them).
sed -i "s/virt_base = text\['vmaddr'\] & ~(0x2000000 - 1)/virt_base = min(s['vmaddr'] for s in segs) \& ~(0x2000000 - 1)/" $T/mkpayload.py
grep -q "virt_base = min(s\['vmaddr'\] for s in segs) & ~(0x2000000 - 1)" $T/mkpayload.py
K=${KERNEL:-$R/xnu-kernel/kernel.development.pandora}
O=$R/phone-$N; rm -rf $O; mkdir -p $O
"$PY" $T/mkadt_pandora.py $O/phone.adt ${ADTFLAGS:-} 2>&1 | tail -2
"$PY" $T/mkpayload.py $K $O/phone.adt $O/payload.bin \
  --cmdline "debug=$DEBUG serial=3 cpus=$CPUS keepsyms=1 -enable_kprintf_spam -noprogress rd=$RD $EXTRA" \
  "${RAMDISK[@]}" 2>&1 | tail -4
if [ -n "${TRUSTCACHE:-}" ]; then
	python3 $T/addtrustcache.py $O/payload.bin $O/payload-tc.bin $TRUSTCACHE
	mv $O/payload-tc.bin $O/payload.bin
fi
mkdir -p $SRC/shim/loader/$N
cp $O/payload.bin $SRC/shim/loader/$N/payload.bin
# The boot logo shim/loader shows without -v: Apple's, from the user's IPSW (Firmware/all_flash/
# applelogo@3x~iphone.im4p), never committed. LOGO=FILE for another; none: a black screen.
LOGO=${LOGO:-}      # none: the loader shows a black screen instead of Apple's logo
if [ -f "$LOGO" ]; then
	python3 -I $SRC/tools/bootlogo.py "$LOGO" $SRC/shim/loader/$N/logo.bin
else
	rm -f $SRC/shim/loader/$N/logo.bin
fi
sha256sum $K $O/payload.bin
