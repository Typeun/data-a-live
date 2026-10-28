#!/bin/bash
# Health check for the whole myron boot chain: host tools, device state, inputs.
#
#   tools/check-env.sh [--kernel PATH] [--rootimg PATH] [--host-only]
#
# One line per check: OK / WARN / FAIL. Every FAIL carries a copy-pasteable fix, and
# the list is repeated at the end. Exit 1 if anything required fails.
# Nothing is written to the phone and nothing is modified on the host.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}
DEVICE=${DEVICE:-myron}
KERNEL=${KERNEL:-$ROOT/xnu/out/kernel.development.pandora}
ROOTIMG=${ROOTIMG:-$ROOT/ios-root.img}
HOST_ONLY=0
NO_INPUTS=0
fails=0
warns=0
fixes=()

while [ $# -gt 0 ]; do
	case $1 in
	--kernel) KERNEL=$2; shift 2 ;;
	--rootimg) ROOTIMG=$2; shift 2 ;;
	--host-only) HOST_ONLY=1; shift ;;
	--no-inputs) NO_INPUTS=1; shift ;;
	-h|--help) sed -n '2,9p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; warns=$((warns + 1)); }
bad()  {
	printf '  FAIL  %s\n' "$1"
	if [ -n "${2:-}" ]; then
		printf '        fix: %s\n' "$2"
		fixes+=("$2")
	fi
	fails=$((fails + 1))
}
need() {
	if command -v "$1" >/dev/null 2>&1; then
		ok "$1: $(command -v "$1")"
	else
		bad "$1 未安装" "$2"
	fi
}

echo "== host"
need adb      "sudo apt install android-tools-adb        # 或把 platform-tools 加进 PATH"
need fastboot "sudo apt install android-tools-fastboot   # 或把 platform-tools 加进 PATH"
need python3  "sudo apt install python3"
command -v base64 >/dev/null 2>&1 && ok "base64: $(command -v base64)" || warn "base64 缺失（日志采集会退回文本模式）"

ndk_ok=0
for d in "${ANDROID_NDK_HOME:-}" "${NDK:-}" "$ROOT"/.ndk/* "$ROOT"/ndk/* "$ROOT"/../tools/ndk/* "$ROOT"/../../../tools/ndk/* \
	"$HOME/Android/Sdk/ndk"/* /opt/android-ndk* "/d/Android/ndk"/*; do
	[ -n "$d" ] || continue
	if ls "$d"/toolchains/llvm/prebuilt/*/bin/clang* >/dev/null 2>&1; then
		ok "NDK: $d"
		ndk_ok=1
		break
	fi
done
if [ "$ndk_ok" = 0 ]; then
	bad "NDK 未找到（编译 pinfile 需要）" \
	    "sdkmanager --install 'ndk;27.2.12479018'  # 或 https://developer.android.com/ndk/downloads"
fi

case "$(uname -s)" in
Linux)
	need apfs-fuse    "sudo apt install apfs-fuse"
	need mkfs.hfsplus "sudo apt install hfsprogs"
	need rsync        "sudo apt install rsync" ;;
Darwin) warn "macOS 主机：根镜像那步要在 Linux 上跑" ;;
*)      warn "非 Linux 主机：根镜像那步需要 apfs-fuse/hfsprogs（虚拟机或 WSL）" ;;
esac

free_gb=$(df -Pk "$ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
if [ "${free_gb:-0}" -ge 20 ]; then ok "磁盘剩余 ${free_gb} GB"; else warn "磁盘只剩 ${free_gb} GB（根镜像 16 GiB，建议 ≥ 20 GB）"; fi

if [ "$NO_INPUTS" = 0 ]; then
echo "== inputs"
if [ -f "$KERNEL" ]; then
	ok "kernel: $KERNEL ($(wc -c < "$KERNEL") bytes)"
else
	bad "kernel 不存在：$KERNEL" \
	    "gh workflow run xnu.yml -R <you>/data-a-live --ref myron -f machine_config=PANDORA"
fi
if [ -f "$ROOTIMG" ]; then
	sz=$(wc -c < "$ROOTIMG")
	if [ "$sz" -ge $((15 * 1024 * 1024 * 1024)) ]; then
		ok "root image: $ROOTIMG ($((sz / 1024 / 1024 / 1024)) GiB)"
	else
		warn "root image 只有 $((sz / 1024 / 1024)) MiB，预期 16 GiB"
	fi
else
	bad "root image 不存在：$ROOTIMG" \
	    "tools/mkroot_myron.sh <iPhone10,3 16.7.16 IPSW> ios-root.img 16G"
fi
[ -f "$ROOT/tools/pinfile/pinfile.c" ] && ok "pinfile 源码在" || bad "tools/pinfile/pinfile.c 缺失"
fi

if [ "$HOST_ONLY" = 0 ]; then
	echo "== device"
	if ! "$ADB" devices | grep -q "device$"; then
		bad "没有 adb 设备" "adb devices   # 插线、开 USB 调试、授权电脑"
	else
		model=$("$ADB" shell getprop ro.product.device 2>/dev/null | tr -d '\r')
		[ "$model" = "$DEVICE" ] && ok "设备: $model" || bad "设备是 '$model'，期望 '$DEVICE'" "DEVICE=<机型> $0"

		slot=$("$ADB" shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')
		case "$slot" in
		_a|_b) ok "slot: $slot" ;;
		*) warn "slot 未知: '$slot'" ;;
		esac

		dmname=$("$ADB" shell su -c "cat /sys/block/dm-50/dm/name" 2>/dev/null | tr -d '\r')
		[ "$dmname" = userdata ] && ok "dm-50 名字: userdata" || \
			warn "dm-50 名字是 '$dmname'（不是 userdata？换 ROM 了？）"

		slaves=$("$ADB" shell su -c "ls /sys/block/dm-50/slaves/" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
		case "$slaves" in
		*sda34*) ok "dm-50 底层: $slaves" ;;
		*) bad "dm-50 底层是 '$slaves'（pinfile 要求 1:1 映射到 userdata）" \
		       "换回 /data 为 f2fs + 单层 dm 的 ROM，或重新评估方案" ;;
		esac

		if "$ADB" shell su -c "test -x /data/local/tmp/pinfile && echo yes" 2>/dev/null | grep -q yes; then
			ok "pinfile 已在手机上"
		else
			bad "pinfile 未推送" "tools/pinfile-build.sh --push"
		fi

		# extent table: the kernel accepts at most 16384 entries (patch 0088)
		img=/data/local/tmp/iosroot.img
		if "$ADB" shell su -c "test -f $img && echo yes" 2>/dev/null | grep -q yes; then
			n=$("$ADB" shell su -c "/data/local/tmp/pinfile extents $img" 2>/dev/null |
				head -1 | awk '{print $1}')
			case "$n" in
			''|*[!0-9]*) warn "读不到根镜像的 extent 数" ;;
			*)
				if [ "$n" -ge 16384 ]; then
					bad "根镜像有 $n 个 extents（内核上限 16384）" \
					    "# 对 /data 做碎片整理或换新格式化后再 create 一次"
				elif [ "$n" -ge 8192 ]; then
					warn "根镜像有 $n 个 extents（接近上限 16384）"
				else
					ok "根镜像 extents: $n"
				fi ;;
			esac
		fi

		if "$ADB" shell su -c "ls /vendor/firmware_mnt/image/adsp.mdt >/dev/null 2>&1 && echo yes" 2>/dev/null | grep -q yes; then
			ok "ADSP 固件在分区里"
		else
			warn "分区里没有 adsp.mdt（需要 pandora_adsp=pack + 固件包）"
		fi
	fi
fi

echo
if [ "${#fixes[@]}" -gt 0 ]; then
	echo "== 修复命令（按顺序）"
	n=1
	for f in "${fixes[@]}"; do
		printf '  %d) %s\n' "$n" "$f"
		n=$((n + 1))
	done
	echo
fi
echo "warns: $warns  fails: $fails"
[ "$fails" = 0 ]
