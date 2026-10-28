#!/bin/bash
# One command before touching anything: patch series, then the offline test suites.
#
#   tools/preflight.sh [--pristine DIR] [--patches DIR] [--no-env]
#
# --pristine  a clean data-a-live checkout to apply the patch series to
#             (default $PRISTINE, else ../pandora-repo if it exists)
# --patches   the patch directory (default ../patches)
# --no-env    skip tools/check-env.sh --host-only
#
# Exit 0 only if every stage passes. Nothing touches the phone.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PATCHES=${PATCHES:-$ROOT/../patches}
PRISTINE=${PRISTINE:-}
RUN_ENV=1
while [ $# -gt 0 ]; do
	case $1 in
	--pristine) PRISTINE=$2; shift 2 ;;
	--patches) PATCHES=$2; shift 2 ;;
	--no-env) RUN_ENV=0; shift ;;
	-h|--help) sed -n '2,11p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
[ -n "$PRISTINE" ] || PRISTINE=$ROOT/../pandora-repo

PY=
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || { echo "needs python3" >&2; exit 1; }

NDK=
for c in "${ANDROID_NDK_HOME:-}" "${NDK:-}" "$ROOT"/.ndk/* "$ROOT"/ndk/* \
	"$ROOT"/../tools/ndk/* "$ROOT"/../../../tools/ndk/* \
	"$HOME/Android/Sdk/ndk"/* /opt/android-ndk* "/d/Android/ndk"/*; do
	[ -n "$c" ] || continue
	if ls "$c"/toolchains/llvm/prebuilt/*/bin/clang* >/dev/null 2>&1; then NDK=$c; break; fi
done

fails=0
say() { printf '%s\n' "$*"; }
stage() { printf '\n== %s\n' "$*"; }
ok()  { printf '  OK    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

if [ "$RUN_ENV" = 1 ] && [ -x "$ROOT/tools/check-env.sh" ]; then
	stage "host environment"
	if bash "$ROOT/tools/check-env.sh" --host-only --no-inputs >/tmp/preflight-env.$$ 2>&1; then
		ok "check-env --host-only --no-inputs"
	else
		bad "check-env --host-only (第一个 FAIL: $(grep -m1 '  FAIL' /tmp/preflight-env.$$ | sed 's/^ *//'))"
	fi
	rm -f /tmp/preflight-env.$$
fi

stage "patch series ($PATCHES)"
if [ ! -d "$PATCHES" ]; then
	bad "no patch directory at $PATCHES"
elif [ ! -d "$PRISTINE/.git" ]; then
	bad "no pristine checkout at $PRISTINE (pass --pristine)"
else
	# keep the tree inside the workspace: native toolchains may be sandboxed to it
	tmp=$(mktemp -d "${PREFLIGHT_TMPBASE:-$ROOT/..}/.preflight.XXXXXX")
	trap 'rm -rf "$tmp"' EXIT
	git -C "$PRISTINE" archive HEAD | tar -x -C "$tmp" 2>/dev/null || {
		cp -a "$PRISTINE/." "$tmp/" && rm -rf "$tmp/.git"; }
	( cd "$tmp" && git init -q . && git add -A >/dev/null 2>&1 )
	applied=0 total=0
	for patch in "$PATCHES"/*.patch; do
		total=$((total + 1))
		if git -C "$tmp" apply "$patch" 2>/dev/null; then
			applied=$((applied + 1))
		else
			bad "$(basename "$patch") does not apply"
		fi
	done
	[ "$applied" = "$total" ] && ok "$applied/$total patches apply"

	stage "offline tests"
	for t in "$tmp"/tools/test_*.py; do
		name=$(basename "$t")
		if ( cd "$tmp" && "$PY" "$t" >/tmp/preflight-$name.$$ 2>&1 ); then
			ok "$name ($(tail -1 /tmp/preflight-$name.$$))"
		else
			bad "$name"
			sed -n 's/^/        /p' /tmp/preflight-$name.$$ | tail -5
		fi
		rm -f /tmp/preflight-$name.$$
	done

	stage "chain self-test"
	if [ -z "$NDK" ]; then
		printf '  SKIP  no NDK, the loader build needs one\n'
	else
		st=$(mktemp -d "${PREFLIGHT_TMPBASE:-$ROOT/..}/.preflight-self.XXXXXX")
		export ANDROID_NDK_HOME=$NDK
		"$PY" "$tmp/tools/mkmacho_test.py" "$st/k.macho" >/dev/null 2>&1
		if RUNDIR="$st/" KERNEL="$st/k.macho" bash "$tmp/tools/boot_ios_linux.sh" --self-test \
			>"$st/log" 2>&1; then
			ok "boot_ios_linux.sh --self-test ($(tail -1 "$st/log"))"
		else
			bad "chain self-test"
			tail -8 "$st/log" | sed 's/^/        /'
		fi
		rm -rf "$st"
	fi
fi

printf '\n'
if [ "$fails" = 0 ]; then
	say "preflight: all stages passed"
	exit 0
fi
say "preflight: $fails stage(s) failed"
exit 1
