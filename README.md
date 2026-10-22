# AndroidTermuxInitializer

adb로 연결한 Android 기기의 Termux에 [opencode](https://opencode.ai)와
[oh-my-openagent](https://github.com/code-yeongyu/oh-my-openagent)(OmO) OpenCode 플러그인을 설치하고,
OmO 에이전트들이 **opencode Zen 무료 모델만** 쓰도록 설정합니다. API 키는 필요 없습니다.

## 실행 방법

설치는 Termux 안에서 `termux/setup-opencode.sh` 가 수행합니다. 이 스크립트는 혼자서 완결되므로 두 가지 방법 중 편한 쪽을 쓰면 됩니다.

| 방법 | 필요한 것 | 특징 |
| --- | --- | --- |
| A. Termux에서 한 줄로 직접 실행 | 기기만 (인터넷 연결) | adb·PC 불필요, IME/입력 포커스 문제 없음. 스크립트를 인터넷에 올려 둬야 함 |
| B. PC에서 adb로 원격 실행 (`termux-init.sh`) | bash + adb (macOS, Linux, Windows는 WSL) | 스크립트를 공개할 필요 없음, 진행 로그를 PC에서 확인 |

### A. Termux에서 한 줄로 설치

Termux를 설치하고 한 번 실행(부트스트랩 완료)한 뒤, Termux에 아래 한 줄을 입력합니다.
`<RAW_URL>` 은 `termux/setup-opencode.sh` 를 올려 둔 주소입니다
(예: GitHub 공개 저장소의 `https://raw.githubusercontent.com/<계정>/AndroidTermuxInitializer/main/termux/setup-opencode.sh`).

```bash
pkg install -y curl && curl -fsSL <RAW_URL> | bash
```
```bash
pkg install -y curl && curl -fsSL https://github.com/r00tIsRoot/AndroidTermuxInitializer/main/termux/setup-opencode.sh | bash
```

옵션은 `bash -s --` 뒤에 붙입니다.

```bash
curl -fsSL <RAW_URL> | bash -s -- --skip-upgrade
curl -fsSL <RAW_URL> | bash -s -- --version 1.19.3 --omo-version 5.1.40
```

스크립트 파일을 이미 기기에 갖고 있다면 `bash setup-opencode.sh [옵션]` 으로 실행해도 됩니다.

> 파이프로 받은 스크립트를 바로 실행하는 방식이므로, 올려 둔 주소의 내용을 신뢰할 수 있을 때만 쓰세요.
> 스크립트에는 키나 개인 정보가 없지만, 공개 저장소에 올리면 누구나 내용을 볼 수 있습니다.

### B. PC에서 adb로 설치

```bash
./termux-init.sh                    # 기기가 하나만 연결된 경우
./termux-init.sh -s <SERIAL>        # 여러 기기 중 선택 (SERIAL: `adb devices` 에 나오는 기기 시리얼)
./termux-init.sh --skip-upgrade     # Termux 패키지 전체 업그레이드 생략
./termux-init.sh -v 1.19.3          # opencode 버전 고정 (기본: 최신)
./termux-init.sh --omo-version 5.1.40  # OmO 플러그인 버전/태그 고정 (기본: latest)
./termux-init.sh --keep-files       # 기기에 설치 스크립트/로그 남기기
```

어느 방법이든 다시 실행하면 opencode 업데이트 + 설정 재생성이 됩니다 (기존 설정은 `.bak` 으로 백업).

### 사전 조건

- 공통: arm64 기기 + Termux(F-Droid / GitHub 릴리스판). 설치 후 **한 번 실행**해 부트스트랩을 끝내 둘 것
- B 방법만:
  - PC에 `adb`(Android platform-tools), 기기에서 USB 디버깅 허용
  - 기기 화면 잠금 해제, Termux 프롬프트가 비어 있을 것 (opencode 등이 전면에서 실행 중이면 안 됨)
  - 스크립트는 `adb shell input text` 로 Termux 프롬프트에 명령을 입력합니다. 입력이 누락되면 Termux를 다시 띄워 최대 3번까지 재시도합니다

## 설치되는 것

| 항목 | 위치 |
| --- | --- |
| opencode 바이너리 (linux-arm64 glibc) + uname 심 | `~/.local/lib/opencode/` |
| 실행 래퍼 | `$PREFIX/bin/opencode` |
| opencode 설정 (자동 업데이트 끔, 플러그인 등록) | `~/.config/opencode/opencode.jsonc`, `tui.json` |
| OmO 에이전트/카테고리 모델 배정 | `~/.omo/omo.jsonc` 의 `[opencode]` 블록 |
| 패키지 | `glibc-repo`, `glibc-runner`, `clang`, `curl`, `nodejs`, `git`, `ripgrep` |

## 모델 배정 (모두 opencode Zen 무료 모델)

| 역할 | 기본 → 대체 |
| --- | --- |
| `sisyphus`(메인), `atlas`, `sisyphus-junior` | `deepseek-v4.1-flash-free` → `minimax-m3.1-flash-free` → `big-pickle` |
| `hephaestus` | `minimax-m3.1-flash-free` → `deepseek-v4.1-flash-free` → `nemotron-3-ultra-free` |
| `prometheus` / `metis` (계획) | `deepseek-v4.1-flash-free` / `minimax-m3.1-flash-free` |
| `oracle` / `momus` (자문·검토) | `nemotron-3-ultra-free` → … |
| `librarian`, `explore` (조사·탐색) | `longcat-2.5-preview-free` → `mimo-v2.6-flash-free` → `deepseek-v4.1-flash-free` |
| `multimodal-looker` (이미지) | `nemotron-3.5-super-vl-free` → `mimo-v2.6-flash-free` |

카테고리(`quick`, `deep-*`, `ultrabrain`, `writing` 등)도 같은 무료 모델들로 배정했고, Zen 동시 요청은 3개로 제한합니다.
기기에서 잰 응답 시간은 대부분 5~9초였고 `glm-5.3-flash-free` 만 40초대로 느려 제외했습니다.

### 무료 모델 데이터 정책 (opencode Zen 문서 기준)

- 학습 미사용·무보관: DeepSeek V4.1 Flash Free, MiniMax M3.1 Flash Free, LongCat 2.5 Preview Free, GLM-5.3-Flash Free → 주력으로 배정
- 무료 기간 동안 모델 개선에 쓰일 수 있음: Big Pickle, MiMo 계열 → 대체용으로만 배정
- NVIDIA Nemotron 무료: 체험용, 사용 기록이 로깅됨(신원과 연결되지 않음) → 자문·검토·이미지에만 배정

민감한 코드에는 대체 모델로 넘어가지 않도록 `fallback_models` 를 조정하세요.

## 동작 방식 메모

- opencode는 Android 빌드가 없어 linux-arm64(glibc) 바이너리를 `glibc-runner` 로더로 실행합니다.
- Android 14+ seccomp가 Bun의 `epoll_pwait2` 를 막아 `Bad system call` 로 죽으므로, 커널 버전을 5.10으로 보고하는 `uname_shim.so` 를 preload해 `epoll_pwait` 로 폴백시킵니다.
- 자동 업데이트는 래퍼를 거치지 않는 바이너리를 받아 깨지므로 끕니다. 업데이트는 스크립트를 다시 실행하세요.
- 한글 IME가 켜져 있으면 `input text` 가 한글로 조합되므로, 명령을 입력하는 동안만 AOSP/Gboard 영문 IME로 바꿨다가 복구합니다.
- OpenCode Zen 무료 모델은 opencode 앱 안에서만 허용됩니다(다른 클라이언트에서는 `FreeTierError`). 그래서 OmO Native가 아니라 OpenCode 플러그인 방식을 씁니다.
- 진행 로그는 기기의 `Download/termux-setup-opencode.log` 에 기록되고 Mac 터미널에 실시간으로 표시됩니다.
