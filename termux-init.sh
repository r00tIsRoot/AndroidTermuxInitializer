#!/usr/bin/env bash
# adb로 연결된 Android 기기의 Termux에 opencode + oh-my-openagent(OmO 플러그인)를 설치하고
# Termux:Widget 에 'make sync' 바로가기를 만든다 (Mac/Linux에서 실행).
#
#   ./termux-init.sh [-s SERIAL] [-v OPENCODE_VERSION] [--omo-version TAG] [--skip-upgrade] [--keep-files]
#                    [--sync-repo URL] [--sync-dir PATH] [--no-sync-widget]
#
# 동작:
#   1. Termux / Termux:Widget 이 없으면 adb install, Termux에 저장소 읽기/쓰기 권한 부여 (adb pm grant)
#   2. termux/setup-opencode.sh, setup-sync-widget.sh 를 기기의 Download 폴더로 push
#   3. Termux를 띄우고, 한글 IME 간섭을 피하려 영문 IME로 잠시 바꾼 뒤 실행 명령을 입력
#   4. 기기의 로그 파일을 따라가며 결과를 출력
#
# 사전 조건: 화면 잠금 해제. 비공개 저장소를 clone 할 때는 기기 화면에서 GitHub 토큰을 입력한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SRC="$SCRIPT_DIR/termux/setup-opencode.sh"
DEVICE_DIR="/storage/emulated/0/Download"
DEVICE_SCRIPT="$DEVICE_DIR/termux-setup-opencode.sh"
SYNC_SRC="$SCRIPT_DIR/termux/setup-sync-widget.sh"
DEVICE_SYNC_SCRIPT="$DEVICE_DIR/termux-setup-sync-widget.sh"
DEVICE_LOG="$DEVICE_DIR/termux-setup-opencode.log"
# 실제로 타이핑하는 명령은 짧을수록 입력 누락 위험이 적다: 인자는 이 런처 파일에 넣는다
DEVICE_LAUNCHER="$DEVICE_DIR/tsi.sh"
TYPED_CMD="bash /sdcard/Download/tsi.sh"
TERMUX_PKG="com.termux"
WIDGET_PKG="com.termux.widget"
TIMEOUT_SEC=1800

SERIAL="${ANDROID_SERIAL:-}"
SETUP_ARGS=()
KEEP_FILES=false
SYNC_WIDGET=true

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (($#)); do
	case "$1" in
		-s) SERIAL="$2"; shift ;;
		-v) SETUP_ARGS+=(--version "$2"); shift ;;
		--omo-version) SETUP_ARGS+=(--omo-version "$2"); shift ;;
		--skip-upgrade) SETUP_ARGS+=(--skip-upgrade) ;;
		--keep-files) KEEP_FILES=true ;;
		--sync-repo|--sync-dir) SETUP_ARGS+=("$1" "$2"); shift ;;
		--no-sync-widget) SETUP_ARGS+=(--no-sync-widget); SYNC_WIDGET=false ;;
		-h|--help) usage ;;
		*) echo "알 수 없는 옵션: $1" >&2; usage 2 ;;
	esac
	shift
done

die() { echo "[x] $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v adb >/dev/null || die "adb를 찾을 수 없습니다 (Android platform-tools 설치 필요)"
[ -f "$SETUP_SRC" ] || die "$SETUP_SRC 가 없습니다"
[ -f "$SYNC_SRC" ] || die "$SYNC_SRC 가 없습니다"

# --- 기기 선택 ---
if [ -z "$SERIAL" ]; then
	DEVICES=()
	while read -r s state _; do
		[ "$state" = "device" ] && DEVICES+=("$s")
	done < <(adb devices | tail -n +2)
	case "${#DEVICES[@]}" in
		0) die "연결된 기기가 없습니다 (USB 디버깅 허용 여부 확인)" ;;
		1) SERIAL="${DEVICES[0]}" ;;
		*)
			echo "여러 기기가 연결되어 있습니다:"
			adb devices -l | tail -n +2 | sed '/^$/d; s/^/  /'
			die "-s SERIAL 로 기기를 지정하세요" ;;
	esac
fi
export ANDROID_SERIAL="$SERIAL"
ash() { adb shell "$@" | tr -d '\r'; }

MODEL="$(ash getprop ro.product.model)"
ABI="$(ash getprop ro.product.cpu.abi)"
info "대상 기기: $MODEL ($SERIAL), Android $(ash getprop ro.build.version.release), $ABI"
[ "$ABI" = "arm64-v8a" ] || die "arm64-v8a 기기만 지원합니다"

# 파이프에 grep -q 를 바로 물리면 pipefail + SIGPIPE 로 오판하므로 출력을 먼저 받아서 검사한다
installed() { grep -qx "package:$1" <<<"$(ash pm list packages "$1")"; }
install_apk() { # URL 이름
	local tmp
	tmp="$(mktemp -d)"
	info "$2 설치: $1"
	curl -fL --progress-bar -o "$tmp/app.apk" "$1" || { rm -rf "$tmp"; die "$2 APK 다운로드 실패"; }
	adb install "$tmp/app.apk" >/dev/null || { rm -rf "$tmp"; die "$2 설치 실패"; }
	rm -rf "$tmp"
}
github_apk() { # 저장소 asset-이름-패턴: 최신 릴리스에서 해당 APK 주소
	curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
		| grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | grep -E "$2" | head -1
}

FRESH_TERMUX=false
if ! installed "$TERMUX_PKG"; then
	# Termux:Widget 등 플러그인과 서명을 맞추기 위해 GitHub 릴리스판을 쓴다
	install_apk "$(github_apk termux/termux-app '_arm64-v8a\.apk$')" Termux
	FRESH_TERMUX=true
fi
if [ "$SYNC_WIDGET" = true ] && ! installed "$WIDGET_PKG"; then
	# Termux 와 같은 서명이어야 설치·연동되므로 Termux 를 받은 곳(GitHub / F-Droid)에 맞춘다
	if grep -q "versionName=.*github" <<<"$(ash dumpsys package "$TERMUX_PKG")"; then
		install_apk "$(github_apk termux/termux-widget '\.apk$')" Termux:Widget
	else
		install_apk "https://f-droid.org/repo/com.termux.widget_1001.apk" Termux:Widget
	fi
fi

focus() { ash dumpsys window | grep -E "mCurrentFocus|mDreamingLockscreen|isKeyguardShowing|mShowingLockscreen" || true; }
if grep -qE "mDreamingLockscreen=true|isKeyguardShowing=true|mShowingLockscreen=true" <<<"$(focus)"; then
	die "기기 화면 잠금을 해제한 뒤 다시 실행하세요"
fi

# --- 파일 전달 ---
info "Termux 저장소 권한 부여"
for p in READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE; do
	ash pm grant "$TERMUX_PKG" "android.permission.$p" 2>/dev/null || true
done

info "설치 스크립트 전송: $DEVICE_SCRIPT, $DEVICE_SYNC_SCRIPT"
adb push "$SETUP_SRC" "$DEVICE_SCRIPT" >/dev/null 2>&1
adb push "$SYNC_SRC" "$DEVICE_SYNC_SCRIPT" >/dev/null 2>&1
ash rm -f "$DEVICE_LOG"

# --- Termux에서 실행 ---
CMD="bash $DEVICE_SCRIPT --log $DEVICE_LOG"
for a in "${SETUP_ARGS[@]+"${SETUP_ARGS[@]}"}"; do CMD+=" $a"; done
LAUNCHER_TMP="$(mktemp)"
printf '%s\n' "$CMD" > "$LAUNCHER_TMP"
adb push "$LAUNCHER_TMP" "$DEVICE_LAUNCHER" >/dev/null 2>&1
rm -f "$LAUNCHER_TMP"

ORIG_IME="$(ash settings get secure default_input_method)"
pick_ascii_ime() {
	local list
	list="$(ash ime list -s -a)"
	for cand in com.android.inputmethod.latin/.LatinIME \
		com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME; do
		grep -qx "$cand" <<<"$list" && { echo "$cand"; return; }
	done
}
ASCII_IME="$(pick_ascii_ime)"
restore_ime() {
	if [ -n "$ASCII_IME" ] && [ -n "$ORIG_IME" ] && [ "$ORIG_IME" != "null" ]; then
		ash ime set "$ORIG_IME" >/dev/null || true
	fi
}
trap restore_ime EXIT

# Termux 화면이 입력을 받지 않는 상태로 남아 있는 경우가 있어(포커스 유실),
# 매번 홈으로 내렸다가 다시 띄워 입력 포커스를 새로 잡는다
launch_termux() {
	ash input keyevent KEYCODE_WAKEUP
	ash input keyevent KEYCODE_HOME
	sleep 1
	ash monkey -p "$TERMUX_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
	for _ in $(seq 1 20); do
		grep -q "mCurrentFocus=.*com.termux" <<<"$(focus)" && break
		sleep 1
	done
	grep -q "mCurrentFocus=.*com.termux" <<<"$(focus)" || die "Termux가 전면에 뜨지 않았습니다"
	sleep 2
}

if [ "$FRESH_TERMUX" = true ]; then
	# 첫 실행 때 Termux가 기본 패키지(부트스트랩)를 푸는 동안은 입력을 받지 않는다
	launch_termux
	info "Termux 첫 실행 부트스트랩 대기 (60초)"
	sleep 60
fi

[ -n "$ASCII_IME" ] || echo "[!] 영문 전용 IME를 찾지 못했습니다. 현재 키보드가 영문 상태인지 확인하세요."

type_command() {
	launch_termux
	if [ -n "$ASCII_IME" ]; then
		ash ime enable "$ASCII_IME" >/dev/null 2>&1 || true
		ash ime set "$ASCII_IME" >/dev/null
		sleep 1
	fi
	ash input keycombination 113 49 2>/dev/null || true # Ctrl+U: 프롬프트 입력 줄 비우기
	# input text 는 공백을 %s 로 바꿔야 한다. IME를 되돌리기 전에 입력이 끝나도록 기다린다
	ash input text "'${TYPED_CMD// /%s}'"
	sleep 1
	ash input keyevent KEYCODE_ENTER
	sleep 2
	restore_ime
}

# input text 가 포커스 문제로 조용히 버려지는 경우가 있어, 기기 스크립트가 시작하자마자 만드는
# 로그 파일이 생기는지로 실행 여부를 확인하고 최대 3번까지 다시 입력한다
STARTED=false
for attempt in 1 2 3; do
	info "명령 입력 (시도 $attempt): $TYPED_CMD  →  $CMD"
	type_command
	for _ in $(seq 1 10); do
		[ -n "$(ash ls "$DEVICE_LOG" 2>/dev/null || true)" ] && { STARTED=true; break; }
		sleep 2
	done
	[ "$STARTED" = true ] && break
done
trap - EXIT
[ "$STARTED" = true ] || die "Termux에서 명령이 실행되지 않았습니다. Termux 프롬프트가 비어 있는지 확인하세요"

# --- 결과 대기 ---
info "설치 진행 중 (기기 로그: $DEVICE_LOG)"
[ "$SYNC_WIDGET" = false ] || info "GitHub 토큰이나 git 이름/이메일을 물으면 기기의 Termux 화면에서 입력하세요"
LINES_SHOWN=0
START=$(date +%s)
while :; do
	LOG_CONTENT="$(ash cat "$DEVICE_LOG" 2>/dev/null || true)"
	TOTAL=$(printf '%s\n' "$LOG_CONTENT" | grep -c '' || true)
	if [ -n "$LOG_CONTENT" ] && [ "$TOTAL" -gt "$LINES_SHOWN" ]; then
		printf '%s\n' "$LOG_CONTENT" | tail -n +"$((LINES_SHOWN + 1))" | grep -v '^__RESULT__' | sed 's/^/  | /'
		LINES_SHOWN=$TOTAL
	fi
	if grep -q '^__RESULT__ OK' <<<"$LOG_CONTENT"; then
		RESULT=OK; break
	elif grep -q '^__RESULT__ FAIL' <<<"$LOG_CONTENT"; then
		RESULT=FAIL; break
	fi
	if (($(date +%s) - START > TIMEOUT_SEC)); then
		RESULT=TIMEOUT; break
	fi
	sleep 3
done

if [ "$KEEP_FILES" = false ] && [ "$RESULT" = OK ]; then
	ash rm -f "$DEVICE_SCRIPT" "$DEVICE_SYNC_SCRIPT" "$DEVICE_LOG" "$DEVICE_LAUNCHER"
fi

case "$RESULT" in
	OK) info "완료: 기기의 Termux에서 'opencode' 를 실행하세요"
		[ "$SYNC_WIDGET" = false ] || info "홈 화면에 Termux:Widget 위젯을 추가하면 동기화 바로가기가 보입니다" ;;
	FAIL) die "설치 실패. 기기 로그: $DEVICE_LOG" ;;
	TIMEOUT) die "시간 초과(${TIMEOUT_SEC}s). Termux 화면과 $DEVICE_LOG 를 확인하세요" ;;
esac
