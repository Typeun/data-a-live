#!/bin/bash
# Capture the FocalTech report buffer the running Android driver parsed, so the frame
# layout can be pinned down without booting our kernel first.
#
#   tools/pull-touch-frame.sh [OUTDIR] [--samples N] [--wait SEC]
#
# Hold a finger on the screen during the countdown. Only sysfs/proc nodes are read:
# nothing is written to the phone, and the driver keeps running.
#
# Output per run: the driver's info and register dump, the firmware string, and N
# samples of fts_touch_point with a hex dump of each.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}
DEVICE=${DEVICE:-myron}
OUT=""
SAMPLES=5
WAIT=5
while [ $# -gt 0 ]; do
	case $1 in
	--samples) SAMPLES=$2; shift 2 ;;
	--wait) WAIT=$2; shift 2 ;;
	-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
	*) OUT=$1; shift ;;
	esac
done
[ -n "$OUT" ] || OUT="$ROOT/device/touch-frames/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

say() { printf '%s\n' "$*"; }
su() { "$ADB" shell su -c "'$*'" | tr -d '\r'; }

say "== device"
model=$("$ADB" shell getprop ro.product.device | tr -d '\r')
[ "$model" = "$DEVICE" ] || { say "expected $DEVICE on adb, got '$model'"; exit 1; }
say "   $model"

say "== driver info"
for node in fts_driver_info fts_dump_reg fts_fw_version; do
	path=/sys/bus/spi/devices/spi19.0/$node
	su "cat $path 2>/dev/null" > "$OUT/$node.txt" || true
	say "   $node -> $(wc -c < "$OUT/$node.txt") bytes"
done
su "cat /proc/tp_fw_version 2>/dev/null" > "$OUT/tp_fw_version.txt" || true

say ""
say "** Hold a finger on the screen for the next ${WAIT}s and keep it there. **"
sleep "$WAIT"

for i in $(seq 1 "$SAMPLES"); do
	su "cat /sys/bus/spi/devices/spi19.0/fts_touch_point 2>/dev/null" > "$OUT/frame-$i.hex"
	say "   sample $i: $(wc -c < "$OUT/frame-$i.hex") bytes"
	sleep 0.3
done

say "== summary"
for f in "$OUT"/frame-*.hex; do
	bytes=$(tr -cd '0-9a-fA-F' < "$f" | wc -c)
	say "   $(basename "$f"): ${bytes} hex chars, head: $(head -c 48 "$f")"
done

say ""
say "saved to $OUT"
say "next: compare the head of each sample with myron_touch_raw=1 output on the first boot."
