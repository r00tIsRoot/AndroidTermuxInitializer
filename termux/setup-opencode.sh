#!/data/data/com.termux/files/usr/bin/bash
# Termux 안에서 실행되는 opencode + oh-my-openagent(OmO 플러그인) 설치 스크립트.
#
#   bash setup-opencode.sh [--version X.Y.Z] [--omo-version TAG] [--log PATH] [--skip-upgrade]
#                          [--sync-repo URL] [--sync-dir PATH] [--no-sync-widget]
#
# opencode는 Android용 빌드가 없으므로 linux-arm64(glibc) 바이너리를 받아
# glibc-runner의 로더로 실행한다. Android 14+ seccomp가 Bun의 epoll_pwait2를
# 차단(SIGSYS)하므로, 커널 버전을 5.10으로 보고하는 uname 심을 preload해서
# Bun이 epoll_pwait로 폴백하게 만든다.
# OmO 플러그인은 opencode Zen 무료 모델만 쓰도록 에이전트/카테고리 모델을 배정한다
# (Zen 무료 모델은 opencode 안에서만 허용되므로 API 키가 필요 없다).
# 이어서 setup-sync-widget.sh 로 Termux:Widget 의 'make sync' 바로가기를 만든다 (--no-sync-widget 으로 생략).
set -euo pipefail

OC_VERSION="${OPENCODE_VERSION:-latest}"
OMO_TAG="${OMO_VERSION:-latest}"
LOG=""
SKIP_UPGRADE=false
SYNC_WIDGET=true
SYNC_ARGS=()

while (($#)); do
	case "$1" in
		--version) OC_VERSION="$2"; shift ;;
		--omo-version) OMO_TAG="$2"; shift ;;
		--log) LOG="$2"; shift ;;
		--skip-upgrade) SKIP_UPGRADE=true ;;
		--sync-repo) SYNC_ARGS+=(--repo "$2"); shift ;;
		--sync-dir) SYNC_ARGS+=(--dir "$2"); shift ;;
		--no-sync-widget) SYNC_WIDGET=false ;;
		-h|--help) sed -n '2,13p' "$0"; exit 0 ;;
		*) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
	esac
	shift
done

if [ -n "$LOG" ]; then
	: > "$LOG"
	exec > >(tee -a "$LOG") 2>&1
fi

result() { echo "__RESULT__ $1"; }
trap 'echo "[x] 실패 (line $LINENO)"; result FAIL' ERR

step() { echo; echo "==> $*"; }

OC_DIR="$HOME/.local/lib/opencode"
OC_CONFIG_DIR="$HOME/.config/opencode"
OMO_CONFIG="$HOME/.omo/omo.jsonc"
WRAPPER="$PREFIX/bin/opencode"
RAW_BASE="${INITIALIZER_RAW_BASE:-https://raw.githubusercontent.com/r00tIsRoot/AndroidTermuxInitializer/main}"
GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)
export DEBIAN_FRONTEND=noninteractive

if [ "$(uname -m)" != "aarch64" ]; then
	echo "aarch64 기기만 지원합니다 (현재: $(uname -m))"
	false
fi

step "패키지 목록 갱신"
apt-get update
if [ "$SKIP_UPGRADE" = false ]; then
	step "설치된 패키지 업그레이드"
	apt-get "${APT_OPTS[@]}" full-upgrade
fi

step "glibc 저장소 / 필수 패키지 설치"
apt-get "${APT_OPTS[@]}" install glibc-repo
apt-get update
# nodejs: 설정 JSON 병합용, git/ripgrep: 에이전트 도구용
apt-get "${APT_OPTS[@]}" install glibc-runner clang curl tar nodejs git ripgrep

step "Termux 추가 키 줄에 세션 목록(DRAWER) 버튼 추가"
# 제스처 탐색에서는 화면 왼쪽 가장자리 스와이프가 '뒤로 가기'로 먹혀 세션 서랍을 열 수 없다.
# 쓰고 있는 extra-keys 가 있으면 첫 줄 끝에 DRAWER 만 끼워 넣고, 없으면 기본 배열 + DRAWER/KEYBOARD 를 쓴다.
TERMUX_PROPS="$HOME/.termux/termux.properties"
[ -f "$TERMUX_PROPS" ] || [ ! -f "$HOME/.config/termux/termux.properties" ] \
	|| TERMUX_PROPS="$HOME/.config/termux/termux.properties"
mkdir -p "$(dirname "$TERMUX_PROPS")"
TERMUX_PROPS="$TERMUX_PROPS" node - <<'EOF'
const fs = require("fs")
const file = process.env.TERMUX_PROPS
const text = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : ""
const lines = text.split("\n")
// 주석이 아닌 extra-keys 설정과, 줄 끝 \ 로 이어지는 다음 줄들까지를 한 덩어리로 찾는다
const start = lines.findIndex((l) => /^\s*extra-keys\s*=/.test(l))
let next
if (start < 0) {
  next = text.replace(/\n*$/, text ? "\n" : "") +
    "extra-keys = [['ESC','/','-','HOME','UP','END','PGUP','DRAWER'], \\\n" +
    "              ['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN','KEYBOARD']]\n"
} else {
  let end = start
  while (end < lines.length - 1 && /\\\s*$/.test(lines[end])) end++
  const value = lines.slice(start, end + 1).join("\n")
  if (/\bDRAWER\b/i.test(value)) {
    console.log(`이미 있음: ${file}`)
    process.exit(0)
  }
  // 따옴표 밖에서 두 번째 [ 이후 처음 나오는 ] 가 첫 번째 키 줄의 끝이다 (']' 같은 키 이름은 건너뜀)
  let depth = 0, quote = "", close = -1
  for (let i = value.indexOf("=") + 1; i > 0 && i < value.length; i++) {
    const ch = value[i]
    if (quote) { if (ch === quote) quote = ""; continue }
    if (ch === "'" || ch === '"') quote = ch
    else if (ch === "[") depth++
    else if (ch === "]" && depth === 2) { close = i; break }
  }
  if (close < 0) {
    console.log(`[!] extra-keys 형식을 알 수 없어 그대로 둡니다: ${file}`)
    process.exit(0)
  }
  const merged = value.slice(0, close).replace(/\s*$/, "") + ",'DRAWER'" + value.slice(close)
  next = [...lines.slice(0, start), ...merged.split("\n"), ...lines.slice(end + 1)].join("\n")
}
if (text) fs.copyFileSync(file, `${file}.bak`)
fs.writeFileSync(file, next)
console.log(`갱신: ${file}`)
EOF
termux-reload-settings 2>/dev/null || echo "Termux를 다시 시작하면 추가 키 설정이 적용됩니다"

if [ "$SYNC_WIDGET" = true ]; then
	# 토큰/이름 입력이 필요할 수 있어 오래 걸리는 opencode 설치보다 먼저 한다
	step "동기화 위젯 설정 (setup-sync-widget.sh)"
	SYNC_SCRIPT=""
	if [ -f "$0" ]; then
		for f in "$(dirname "$0")/setup-sync-widget.sh" "$(dirname "$0")/termux-setup-sync-widget.sh"; do
			if [ -f "$f" ]; then SYNC_SCRIPT="$f"; break; fi
		done
	fi
	SYNC_TMP=""
	if [ -z "$SYNC_SCRIPT" ]; then
		SYNC_TMP="$(mktemp)"
		curl -fsSL -o "$SYNC_TMP" "$RAW_BASE/termux/setup-sync-widget.sh"
		SYNC_SCRIPT="$SYNC_TMP"
	fi
	# stdin 은 curl | bash 의 스크립트 본문일 수 있으므로 넘기지 않는다 (입력은 /dev/tty 로 받음)
	if ! bash "$SYNC_SCRIPT" "${SYNC_ARGS[@]+"${SYNC_ARGS[@]}"}" </dev/null; then
		echo "[x] 동기화 위젯 설정 실패 (--no-sync-widget 으로 건너뛸 수 있습니다)"
		false
	fi
	[ -z "$SYNC_TMP" ] || rm -f "$SYNC_TMP"
fi

step "opencode 버전 확인"
META="$(curl -fsSL "https://registry.npmjs.org/opencode-linux-arm64/$OC_VERSION")"
OC_VERSION="$(printf '%s' "$META" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
SHASUM="$(printf '%s' "$META" | grep -o '"shasum":"[^"]*"' | head -1 | cut -d'"' -f4)"
echo "opencode-linux-arm64 $OC_VERSION"

step "opencode 바이너리 다운로드"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TGZ="$TMP/opencode.tgz"
curl -fL --progress-bar -o "$TGZ" \
	"https://registry.npmjs.org/opencode-linux-arm64/-/opencode-linux-arm64-$OC_VERSION.tgz"
if [ -n "$SHASUM" ]; then
	echo "$SHASUM  $TGZ" | sha1sum -c -
fi
tar xzf "$TGZ" -C "$TMP"
mkdir -p "$OC_DIR"
install -m 755 "$TMP/package/bin/opencode" "$OC_DIR/opencode"

step "uname 심 빌드"
cat > "$OC_DIR/uname_shim.c" <<'EOF'
/* Report kernel 5.10 so Bun falls back from epoll_pwait2 (blocked by Android seccomp). */
struct utsname { char sysname[65], nodename[65], release[65], version[65], machine[65], domainname[65]; };

int uname(struct utsname *buf) {
    register long x0 __asm__("x0") = (long)buf;
    register long x8 __asm__("x8") = 160; /* __NR_uname */
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
    if (x0 < 0) return -1;
    const char rel[] = "5.10.0-android";
    for (unsigned i = 0; i < sizeof(rel); i++) buf->release[i] = rel[i];
    return 0;
}
EOF
clang --target=aarch64-linux-gnu -O2 -fPIC -shared -nostdlib -fno-stack-protector \
	-o "$OC_DIR/uname_shim.so" "$OC_DIR/uname_shim.c"

step "실행 래퍼 작성: $WRAPPER"
cat > "$WRAPPER" <<EOF
#!$PREFIX/bin/bash
# opencode (linux-arm64 glibc build) via glibc loader; uname shim avoids seccomp-blocked epoll_pwait2
OC_DIR="\$HOME/.local/lib/opencode"
unset LD_PRELOAD
exec $GLIBC_LD \\
  --preload "\$OC_DIR/uname_shim.so" "\$OC_DIR/opencode" "\$@"
EOF
chmod 755 "$WRAPPER"

step "셸 PATH 정리"
# 공식 설치 스크립트가 넣는 ~/.opencode/bin PATH는 래퍼보다 먼저 잡혀 실행이 깨지므로 비활성화
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile"; do
	if [ -f "$rc" ] && grep -qE '^[^#]*\.opencode/bin' "$rc"; then
		sed -i -E 's|^([^#]*\.opencode/bin.*)$|# (disabled: opencode runs via $PREFIX/bin/opencode wrapper) \1|' "$rc"
		echo "PATH 설정 비활성화: $rc"
	fi
done

step "opencode 설정: 자동 업데이트 끄기 + OmO 플러그인 등록 (oh-my-openagent@$OMO_TAG)"
mkdir -p "$OC_CONFIG_DIR"
# 자동 업데이트는 래퍼를 거치지 않는 바이너리를 받으므로 끈다.
# opencode.jsonc(또는 .json)와 tui.json 의 plugin 배열에 플러그인을 넣고, 다른 항목은 유지한다.
OC_CONFIG_DIR="$OC_CONFIG_DIR" PLUGIN="oh-my-openagent@$OMO_TAG" node - <<'EOF'
const fs = require("fs"), path = require("path")
const dir = process.env.OC_CONFIG_DIR, plugin = process.env.PLUGIN
const isOmo = (e) => typeof e === "string" && /^(oh-my-openagent|oh-my-opencode)(@|$)/.test(e)
// 주석과 끝 쉼표를 걷어낸 뒤 파싱 (문자열 안의 // 는 건드리지 않음)
const parseJsonc = (text) => JSON.parse(
  text.replace(/("(?:\\.|[^"\\])*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (m, str) => str ?? "")
      .replace(/,(\s*[}\]])/g, "$1"))
function update(file, mutate) {
  let config = {}
  if (fs.existsSync(file)) {
    config = parseJsonc(fs.readFileSync(file, "utf8"))
    fs.copyFileSync(file, `${file}.bak`)
  }
  mutate(config)
  fs.writeFileSync(file, JSON.stringify(config, null, 2) + "\n")
  console.log(`갱신: ${file}`)
}
const withPlugin = (c) => {
  const entries = [].concat(c.plugin ?? []).filter((e) => !isOmo(e))
  c.plugin = [...entries, plugin]
}
const main = ["opencode.jsonc", "opencode.json"].map((n) => path.join(dir, n)).find(fs.existsSync)
  ?? path.join(dir, "opencode.jsonc")
update(main, (c) => {
  c.$schema ??= "https://opencode.ai/config.json"
  c.autoupdate = false
  withPlugin(c)
})
update(path.join(dir, "tui.json"), withPlugin)
EOF

step "OmO 에이전트/카테고리 모델 배정: $OMO_CONFIG"
mkdir -p "$(dirname "$OMO_CONFIG")"
if [ -f "$OMO_CONFIG" ]; then
	BACKUP="$OMO_CONFIG.bak-$(date +%Y%m%d%H%M%S)"
	cp "$OMO_CONFIG" "$BACKUP"
	echo "기존 설정 백업: $BACKUP"
fi
cat > "$OMO_CONFIG" <<'EOF'
// AndroidTermuxInitializer가 생성: OmO 플러그인이 opencode Zen 무료 모델만 쓰도록 배정.
// 학습 미사용·무보관 모델(deepseek/minimax/longcat flash free)을 우선하고,
// 한도/오류 시 fallback_models 순서로 넘어간다.
{
  "$schema": "https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/omo.schema.json",

  "[opencode]": {
    "agents": {
      // 메인 오케스트레이터 / 실행 담당
      "sisyphus": { "model": "opencode/deepseek-v4.1-flash-free", "fallback_models": ["opencode/minimax-m3.1-flash-free", "opencode/big-pickle"] },
      "hephaestus": { "model": "opencode/minimax-m3.1-flash-free", "fallback_models": ["opencode/deepseek-v4.1-flash-free", "opencode/nemotron-3-ultra-free"] },
      "atlas": { "model": "opencode/deepseek-v4.1-flash-free", "fallback_models": ["opencode/minimax-m3.1-flash-free", "opencode/big-pickle"] },
      "sisyphus-junior": { "model": "opencode/deepseek-v4.1-flash-free", "fallback_models": ["opencode/minimax-m3.1-flash-free", "opencode/big-pickle"] },

      // 계획 / 자문 / 검토: 메인과 다른 계열을 섞어 교차 검토
      "prometheus": { "model": "opencode/deepseek-v4.1-flash-free", "fallback_models": ["opencode/minimax-m3.1-flash-free"] },
      "metis": { "model": "opencode/minimax-m3.1-flash-free", "fallback_models": ["opencode/deepseek-v4.1-flash-free"] },
      "oracle": { "model": "opencode/nemotron-3-ultra-free", "fallback_models": ["opencode/minimax-m3.1-flash-free", "opencode/deepseek-v4.1-flash-free"] },
      "momus": { "model": "opencode/nemotron-3-ultra-free", "fallback_models": ["opencode/longcat-2.5-preview-free", "opencode/minimax-m3.1-flash-free"] },

      // 조사 / 탐색: 가볍고 빠른 모델
      "librarian": { "model": "opencode/longcat-2.5-preview-free", "fallback_models": ["opencode/mimo-v2.6-flash-free", "opencode/deepseek-v4.1-flash-free"] },
      "explore": { "model": "opencode/longcat-2.5-preview-free", "fallback_models": ["opencode/mimo-v2.6-flash-free", "opencode/deepseek-v4.1-flash-free"] },

      // 이미지 해석: 비전 모델
      "multimodal-looker": { "model": "opencode/nemotron-3.5-super-vl-free", "fallback_models": ["opencode/mimo-v2.6-flash-free"] }
    },

    "categories": {
      "visual-engineering": { "model": "opencode/minimax-m3.1-flash-free", "fallback_models": ["opencode/deepseek-v4.1-flash-free"] },
      "ultrabrain": { "model": "opencode/nemotron-3-ultra-free", "fallback_models": ["opencode/deepseek-v4.1-flash-free", "opencode/minimax-m3.1-flash-free"] },
      "deep-low": { "model": "opencode/deepseek-v4.1-flash-free", "fallback_models": ["opencode/minimax-m3.1-flash-free", "opencode/nemotron-3-ultra-free"] },
      "deep-high": { "model": "opencode/nemotron-3-ultra-free", "fallback_models": ["opencode/deepseek-v4.1-flash-free", "opencode/minimax-m3.1-flash-free"] },
      "artistry": { "model": "opencode/minimax-m3.1-flash-free", "fallback_models": ["opencode/big-pickle"] },
      "quick": { "model": "opencode/longcat-2.5-preview-free", "fallback_models": ["opencode/mimo-v2.6-flash-free", "opencode/deepseek-v4.1-flash-free"] },
      "unspecified-low": { "model": "opencode/deepseek-v4.1-flash-free", "fallback_models": ["opencode/longcat-2.5-preview-free"] },
      "unspecified-high": { "model": "opencode/deepseek-v4.1-flash-free", "fallback_models": ["opencode/minimax-m3.1-flash-free", "opencode/nemotron-3-ultra-free"] },
      "writing": { "model": "opencode/minimax-m3.1-flash-free", "fallback_models": ["opencode/deepseek-v4.1-flash-free"] }
    },

    // 무료 등급 한도를 고려해 Zen 동시 요청 수를 제한
    "background_task": { "providerConcurrency": { "opencode": 3 } }
  }
}
EOF

step "동작 확인"
hash -r
cd "$HOME"
echo "opencode $(opencode --version)"
# 첫 실행에서 opencode가 플러그인을 내려받아 로드한다
FIRST_MODEL="$(timeout 180 opencode models opencode 2>/dev/null | grep -m1 -- '-free' || true)"
if [ -z "$FIRST_MODEL" ]; then
	echo "[x] 무료 모델 목록 조회 실패 — 네트워크 또는 런타임 문제"
	false
fi
echo "무료 모델 조회 성공 (예: $FIRST_MODEL)"
AGENTS="$(timeout 300 opencode agent list 2>/dev/null || true)"
if grep -qi sisyphus <<<"$AGENTS"; then
	echo "[ok] OmO 플러그인 로드됨 (sisyphus 에이전트 확인)"
else
	echo "[!] OmO 에이전트가 보이지 않습니다. opencode를 한 번 실행해 플러그인 설치가 끝났는지 확인하세요."
fi
REPLY="$(timeout 300 opencode run --agent sisyphus "Reply with exactly one word: pong" 2>&1 | tail -3 || true)"
if grep -qi pong <<<"$REPLY"; then
	echo "[ok] sisyphus 응답 확인"
else
	echo "[!] sisyphus 응답 확인 실패: $REPLY"
fi

echo
echo "설치 완료. Termux에서 'opencode' 를 실행하세요."
result OK
