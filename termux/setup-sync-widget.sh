#!/data/data/com.termux/files/usr/bin/bash
# Termux:Widget 에 Git 저장소 동기화(make sync) 바로가기를 만드는 스크립트 (Termux 안에서 실행).
#
#   bash setup-sync-widget.sh [--repo URL] [--dir PATH] [--name NAME] [--target TARGET]
#
# 1. make/git 설치, 공유 저장소(~/storage) 연결 (termux-setup-storage)
# 2. 저장소 폴더가 없으면 clone (비공개 저장소는 GitHub 사용자명 + 토큰(PAT) 입력, ~/.git-credentials 에 저장)
# 3. git 사용자 정보, safe.directory, core.fileMode 설정
# 4. Termux:Widget 앱이 없으면 APK를 받아 설치 화면을 띄움
# 5. ~/.shortcuts/NAME 에 'cd DIR && make TARGET' 스크립트 작성
set -euo pipefail

REPO="${SYNC_REPO:-https://github.com/r00tIsRoot/PrivateMemo.git}"
DIR="${SYNC_DIR:-$HOME/storage/downloads/PrivateMemo}"
NAME=""
TARGET="sync"

while (($#)); do
	case "$1" in
		--repo) REPO="$2"; shift ;;
		--dir) DIR="$2"; shift ;;
		--name) NAME="$2"; shift ;;
		--target) TARGET="$2"; shift ;;
		-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
		*) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
	esac
	shift
done
NAME="${NAME:-$(basename "$DIR") $TARGET}"
SHORTCUT="$HOME/.shortcuts/$NAME"
APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)
export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "==> $*"; }
die() { echo "[x] $*"; exit 1; }
# curl | bash 로 실행되면 stdin 이 스크립트 본문이므로, 사용자 입력은 항상 터미널에서 직접 받는다
has_tty() { { : </dev/tty; } 2>/dev/null; }
ask() { local v; read -r -p "$1" v </dev/tty; printf '%s' "$v"; }

step "make / git 설치"
apt-get "${APT_OPTS[@]}" install make git

step "공유 저장소 연결 (~/storage)"
if ! ls "$HOME/storage/downloads/" >/dev/null 2>&1; then
	echo "기기에 저장소 권한 요청 창이 뜨면 '허용'을 누르세요."
	# 이미 ~/storage 가 있으면 다시 만들지 묻는다
	echo y | termux-setup-storage || true
	for _ in $(seq 1 60); do
		ls "$HOME/storage/downloads/" >/dev/null 2>&1 && break
		sleep 1
	done
	ls "$HOME/storage/downloads/" >/dev/null 2>&1 || die "저장소 권한이 없습니다. 권한을 허용한 뒤 다시 실행하세요"
fi
echo "확인: $HOME/storage/downloads"

# 공유 저장소의 파일은 Termux 사용자 소유가 아니어서 git 이 'dubious ownership' 으로 거부한다
REAL_DIR="$(realpath -m "$DIR")"
SAFE_DIRS="$(git config --global --get-all safe.directory 2>/dev/null || true)"
for d in "$DIR" "$REAL_DIR"; do
	if ! grep -qxF "$d" <<<"$SAFE_DIRS"; then
		git config --global --add safe.directory "$d"
		SAFE_DIRS+=$'\n'"$d"
	fi
done
# 토큰을 한 번만 입력하도록 자격 증명을 저장한다 (다른 helper 가 이미 있으면 유지)
if [ -z "$(git config --global credential.helper || true)" ]; then
	git config --global credential.helper store
fi

if [ -d "$DIR/.git" ]; then
	step "저장소 확인: $DIR"
	git -C "$DIR" config core.fileMode false
	echo "원격 접속 확인 (자격 증명이 없으면 GitHub 사용자명과 토큰(PAT)을 물어봅니다)"
	git -C "$DIR" fetch
else
	step "저장소 clone: $REPO → $DIR"
	if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
		die "$DIR 가 git 저장소가 아닌데 비어 있지 않습니다. 옮기거나 지운 뒤 다시 실행하세요"
	fi
	has_tty || echo "[!] 터미널 입력을 받을 수 없어 비공개 저장소라면 clone이 실패합니다"
	echo "비공개 저장소라면 Username 에 GitHub 사용자명, Password 에 토큰(PAT, repo 권한)을 입력하세요."
	git clone "$REPO" "$DIR"
	git -C "$DIR" config core.fileMode false
fi

step "git 사용자 정보"
if [ -z "$(git -C "$DIR" config user.name || true)" ] || [ -z "$(git -C "$DIR" config user.email || true)" ]; then
	has_tty || die "git user.name / user.email 이 없습니다. 'git config --global user.name ...' 로 설정한 뒤 다시 실행하세요"
	echo "커밋에 쓸 이름과 이메일을 입력하세요 (전역 git 설정에 저장)."
	git config --global user.name "$(ask 'user.name: ')"
	git config --global user.email "$(ask 'user.email: ')"
fi
echo "$(git -C "$DIR" config user.name) <$(git -C "$DIR" config user.email)>"
if ! make -n -C "$DIR" "$TARGET" >/dev/null 2>&1; then
	echo "[!] $DIR 의 Makefile 에 '$TARGET' 타깃이 없습니다. 위젯은 만들지만 실행 시 실패합니다."
fi

step "바로가기 작성: $SHORTCUT"
mkdir -p "$HOME/.shortcuts"
chmod 700 "$HOME/.shortcuts"
cat > "$SHORTCUT" <<EOF
#!$PREFIX/bin/bash
# AndroidTermuxInitializer가 생성: Termux:Widget에서 $DIR 의 'make $TARGET' 실행
cd $(printf '%q' "$DIR") || { read -r -p "저장소 폴더가 없습니다. Enter로 닫기"; exit 1; }
make $(printf '%q' "$TARGET")
status=\$?
echo
if [ \$status -eq 0 ]; then echo "완료"; else echo "실패 (exit \$status)"; fi
read -r -p "Enter를 누르면 닫힙니다"
exit \$status
EOF
chmod 700 "$SHORTCUT"

step "Termux:Widget 앱 확인"
PKGS="$(pm list packages com.termux 2>/dev/null || true)"
if grep -qx "package:com.termux.widget" <<<"$PKGS"; then
	echo "설치됨: com.termux.widget"
elif ! grep -qx "package:com.termux" <<<"$PKGS"; then
	echo "[!] 설치 여부를 확인할 수 없습니다. Termux:Widget 이 없다면 Termux와 같은 곳(F-Droid/GitHub)에서 설치하세요."
else
	# Termux:Widget 은 Termux와 서명이 같아야 하므로 Termux를 받은 곳에서 받는다
	case "${TERMUX_APK_RELEASE:-}" in
		GITHUB) APK_URL="https://github.com/termux/termux-widget/releases/download/v0.15.0/termux-widget-app_v0.15.0%2Bgithub.debug.apk" ;;
		F_DROID) APK_URL="https://f-droid.org/repo/com.termux.widget_1001.apk" ;;
		*) APK_URL="" ;;
	esac
	if [ -z "$APK_URL" ]; then
		echo "[!] Termux 배포처(${TERMUX_APK_RELEASE:-알 수 없음})용 Termux:Widget 을 직접 설치하세요."
	else
		APK="$HOME/storage/downloads/termux-widget.apk"
		curl -fL --progress-bar -o "$APK" "$APK_URL"
		echo "설치 화면을 엽니다. '알 수 없는 앱 설치' 허용을 물으면 Termux에 허용한 뒤 설치하세요."
		termux-open "$APK" || echo "[!] 설치 화면을 열지 못했습니다. 파일 앱에서 Download/termux-widget.apk 를 여세요."
	fi
fi

echo
echo "위젯 준비 완료: 홈 화면을 길게 눌러 위젯 → Termux:Widget 을 추가한 뒤 '$NAME' 을 누르면 $DIR 에서 'make $TARGET' 를 실행합니다."
