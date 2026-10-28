#!/bin/bash
# Collect what survives a fastboot boot attempt: the Android kernel log, and the iOS
# kernel log if the boot was started with a pinned log file (patch 0129).
#
#   tools/collect-boot-log.sh [--wait SEC] [--log /data/local/tmp/ioslog.img] [--out DIR]
#
# Run it right after `boot_ios_linux.sh` (or in parallel in another shell): it waits for
# the phone to come back to Android, then pulls everything readable. Nothing is written to
# the phone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}
WAIT=240
LOG=/data/local/tmp/ioslog.img
OUT=""
while [ $# -gt 0 ]; do
	case $1 in
	--wait) WAIT=$2; shift 2 ;;
	--log) LOG=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
[ -n "$OUT" ] || OUT="$ROOT/device/boot-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }
su() { "$ADB" shell su -c "'$*'" | tr -d '\r'; }

say "== waiting up to ${WAIT}s for the phone to answer on adb"
seen=0
for _ in $(seq 1 "$WAIT"); do
	if "$ADB" devices | grep -q "device$"; then seen=1; break; fi
	sleep 1
done
if [ "$seen" = 0 ]; then
	say "   no adb after ${WAIT}s: the kernel has no USB (expected before level 8) or is stuck"
	say "   photograph the screen now; the framebuffer is the only log"
	say "   then, once Android is back: $0 --wait 0 --out $OUT"
	exit 1
fi
say "   device is back"

say "== android side"
"$ADB" shell getprop ro.boot.bootreason > "$OUT/bootreason.txt" 2>/dev/null || true
say "   bootreason: $(cat "$OUT/bootreason.txt" 2>/dev/null | tr -d '\r')"
su "dmesg" > "$OUT/android-dmesg.txt" 2>/dev/null || true
say "   android dmesg: $(wc -l < "$OUT/android-dmesg.txt") lines"
grep -i -E "reboot|panic|watchdog|fastboot" "$OUT/android-dmesg.txt" | tail -20 > "$OUT/reboot-hints.txt" 2>/dev/null || true

say "== ios log file ($LOG)"
if su "test -f $LOG && echo yes" | grep -q yes; then
	su "cat $LOG | base64" > "$OUT/ioslog.b64" 2>/dev/null || true
	if base64 -d < "$OUT/ioslog.b64" > "$OUT/ioslog.bin" 2>/dev/null; then
		rm -f "$OUT/ioslog.b64"
		say "   ioslog.bin: $(wc -c < "$OUT/ioslog.bin") bytes"
		head -c 200 "$OUT/ioslog.bin" | tr -c '[:print:]\n' '.' > "$OUT/ioslog-head.txt" || true
		say "   head: $(cat "$OUT/ioslog-head.txt")"
	else
		say "   base64 decode failed; raw text kept in ioslog.b64"
	fi
else
	say "   no log file: the boot was started without --log, or it never got to write"
	say "   next time: boot_ios_linux.sh ... --log /data/local/tmp/ioslog.img ufsrw=1"
fi

say ""
say "saved to $OUT"
ls -l "$OUT"
