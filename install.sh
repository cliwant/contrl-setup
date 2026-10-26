#!/usr/bin/env bash
#
# install.sh — CONTRL 설치 (macOS / Linux)
#   1. git 설치
#   2. GitHub CLI(gh) 설치
#   3. (macOS) python3 확인 · Node.js 18+ 준비 — 실패해도 경고만 하고 계속한다
#   4. Claude Code 설치
#   5. GitHub PAT 저장 + git credential helper 연결
#   6. CONTRL 플러그인 설치 — 실패하면 원인을 안내하고 최대 3회까지 토큰 재입력
#      (플러그인 설치가 저장소 접근 확인을 겸한다 — 별도의 clone 검증은 하지 않는다)
#
# Homebrew는 선택 사항이다. 없으면:
#   - git  : Xcode Command Line Tools 로 설치
#   - gh   : GitHub 공식 릴리스 바이너리를 $INSTALL_PREFIX 에 설치 (sudo 불필요)
#   - node : nodejs.org 공식 tarball 을 $INSTALL_PREFIX 에 설치 (sudo 불필요, Intel 도 됨)
#   Homebrew 자동 설치는 하지 않는다 — 공식 설치기는 NONINTERACTIVE=1 이면 sudo 비밀번호를
#   묻지 않고 실패하고, Intel Mac 에서는 바로 중단한다.
#
# 사용법:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/cliwant/contrl-setup/main/install.sh)"
#
# `curl … | bash` 형태로는 배포하지 않는다. 그 형태에서는 bash의 stdin이 터미널이 아니라
# curl의 파이프가 되어 PAT 입력 프롬프트가 동작하지 않는다. 위의 커맨드 치환 형태는
# 스크립트를 문자열로 먼저 받으므로 stdin이 터미널로 유지된다.
#
# 개발용 환경변수:
#   GITHUB_PAT           비대화형 실행 (첫 시도에만 사용)
#   CONTRL_SKIP_VERIFY   플러그인 설치(저장소 접근 확인) 생략
#   CONTRL_NO_BREW       brew가 있어도 릴리스 바이너리 사용
#   INSTALL_PREFIX       brew 없이 gh·node를 설치할 위치 (기본: $HOME/.local)
#

set -euo pipefail

REPO="cliwant/contrl-harness"
MARKETPLACE="contrl-harness"     # marketplace.json 의 name
PLUGIN="contrl"                  # plugin.json 의 name
INSTALL_PREFIX="${INSTALL_PREFIX:-$HOME/.local}"
MAX_ATTEMPTS=3
SCRIPT_URL="https://raw.githubusercontent.com/cliwant/contrl-setup/main/install.sh"
# scopes 파라미터로 repo·admin:org 체크박스를 미리 채워 둔다 — 스코프 누락이 접근 실패의 절반이다.
TOKEN_URL="https://github.com/settings/tokens/new?scopes=repo,admin:org&description=CONTRL%20harness&default_expires_at=none"

SKIP_VERIFY=0; [[ -n "${CONTRL_SKIP_VERIFY:-}" ]] && SKIP_VERIFY=1
NO_BREW=0;     [[ -n "${CONTRL_NO_BREW:-}"     ]] && NO_BREW=1

# ── 로깅 ──────────────────────────────────────────────────────────────
info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()   { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ── 임시 디렉토리 정리 ────────────────────────────────────────────────
# RETURN 트랩은 함수 지역이 아니라서 스코프를 벗어난 변수를 참조하게 된다.
# 정리 대상을 전역 배열에 모으고 EXIT 트랩 하나로만 처리한다.
# (macOS 기본 bash 3.2 에서 빈 배열 확장 시 set -u 오류를 피하는 문법 사용)
CLEANUP_DIRS=()
cleanup_all() {
  local d
  for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
  return 0
}
trap cleanup_all EXIT INT TERM

register_cleanup() { CLEANUP_DIRS+=("$1"); }

# ── 플랫폼 / 설치 경로 감지 ───────────────────────────────────────────
OS="$(uname -s)"
PKG=""

case "$OS" in
  Darwin)
    if [[ "$NO_BREW" -eq 0 ]] && have brew; then
      PKG="brew"
    else
      PKG="macos-manual"   # brew 없이 CLT + 릴리스 바이너리로 처리
    fi
    ;;
  Linux)
    if   [[ "$NO_BREW" -eq 0 ]] && have brew; then PKG="brew"
    elif have apt-get; then PKG="apt"
    elif have dnf;     then PKG="dnf"
    elif have yum;     then PKG="yum"
    elif have pacman;  then PKG="pacman"
    else PKG="linux-manual"
    fi
    ;;
  *)
    die "지원하지 않는 OS: $OS (Windows는 install.ps1 을 사용하세요)"
    ;;
esac

SUDO=""
if [[ "$PKG" =~ ^(apt|dnf|yum|pacman)$ && "$EUID" -ne 0 ]]; then
  have sudo || die "sudo가 필요합니다."
  SUDO="sudo"
fi

info "플랫폼: $OS / 설치 방식: $PKG"

# ── 1. git 설치 ───────────────────────────────────────────────────────
install_git() {
  # macOS의 /usr/bin/git 은 CLT 미설치 시 설치 안내만 띄우는 셸이다.
  # 실제 동작 여부는 --version 실행으로 판정한다.
  if have git && git --version >/dev/null 2>&1; then
    ok "git 이미 설치됨 ($(git --version))"
    return
  fi

  info "git 설치 중..."
  case "$PKG" in
    brew)   brew install git ;;
    apt)    $SUDO apt-get update -qq && $SUDO apt-get install -y git ;;
    dnf)    $SUDO dnf install -y git ;;
    yum)    $SUDO yum install -y git ;;
    pacman) $SUDO pacman -Sy --noconfirm git ;;
    macos-manual)
      if xcode-select -p >/dev/null 2>&1; then
        die "Command Line Tools는 설치돼 있는데 git이 동작하지 않습니다. 'sudo xcode-select --reset' 후 다시 시도해 보세요."
      fi
      warn "Xcode Command Line Tools 설치 창이 뜹니다. 설치가 끝나면 아래 명령어를 다시 실행해 주세요:
        bash -c \"\$(curl -fsSL $SCRIPT_URL)\""
      xcode-select --install || true
      exit 0
      ;;
    linux-manual)
      die "지원되는 패키지 매니저가 없습니다. git을 수동 설치한 뒤 다시 실행해 주세요."
      ;;
  esac
  have git || die "git 설치 실패"
  ok "git 설치 완료 ($(git --version))"
}

# ── gh: 공식 릴리스 바이너리 설치 (brew/패키지매니저 불필요, sudo 불필요) ──
install_gh_from_release() {
  have curl || die "curl이 필요합니다."

  local arch asset_os ext ver url tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) die "지원하지 않는 아키텍처: $(uname -m)" ;;
  esac

  if [[ "$OS" == "Darwin" ]]; then asset_os="macOS"; ext="zip"
  else                            asset_os="linux"; ext="tar.gz"
  fi

  # /releases/latest 리다이렉트 URL에서 버전 태그를 추출한다 (jq 불필요).
  info "최신 gh 릴리스 확인 중..."
  ver="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
          https://github.com/cli/cli/releases/latest \
        | sed -E 's#.*/tag/v?##')"
  [[ -n "$ver" ]] || die "gh 최신 버전을 확인하지 못했습니다."

  url="https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_${asset_os}_${arch}.${ext}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gh-install.XXXXXX")"
  register_cleanup "$tmp"

  info "gh ${ver} 다운로드 중 (${asset_os}/${arch})..."
  if ! curl -fsSL "$url" -o "$tmp/gh.$ext"; then
    # 구버전 macOS 릴리스는 tar.gz 로 배포됐다.
    if [[ "$ext" == "zip" ]]; then
      ext="tar.gz"
      url="https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_${asset_os}_${arch}.${ext}"
      curl -fsSL "$url" -o "$tmp/gh.$ext" || die "gh 다운로드 실패: $url"
    else
      die "gh 다운로드 실패: $url"
    fi
  fi

  info "압축 해제 및 설치: $INSTALL_PREFIX"
  if [[ "$ext" == "zip" ]]; then
    have unzip || die "unzip이 필요합니다."
    unzip -q "$tmp/gh.$ext" -d "$tmp"
  else
    tar -xzf "$tmp/gh.$ext" -C "$tmp"
  fi

  local src
  src="$(find "$tmp" -maxdepth 1 -type d -name 'gh_*' | head -n1)"
  [[ -n "$src" ]] || die "압축 해제된 gh 디렉토리를 찾지 못했습니다."

  mkdir -p "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/share/man/man1"
  install -m 0755 "$src/bin/gh" "$INSTALL_PREFIX/bin/gh"
  cp -f "$src"/share/man/man1/*.1 "$INSTALL_PREFIX/share/man/man1/" 2>/dev/null || true

  rm -rf "$tmp"
  export PATH="$INSTALL_PREFIX/bin:$PATH"

  # 셸 설정 파일은 임의로 건드리지 않고 안내만 한다.
  # (node 를 이 경로에 설치하면 node 단계가 같은 경로를 셸 프로필에 등록한다 — 그 줄도 찾는다)
  if ! grep -qs "$INSTALL_PREFIX/bin" "${HOME}/.zshrc" "${HOME}/.bashrc" \
         "${HOME}/.zprofile" "${HOME}/.bash_profile" "${HOME}/.bash_login" "${HOME}/.profile" 2>/dev/null; then
    warn "새 터미널에서도 gh를 쓰려면 ~/.zshrc 또는 ~/.bashrc 에 아래 한 줄을 추가하세요:
        export PATH=\"$INSTALL_PREFIX/bin:\$PATH\""
  fi
}

# ── 2. gh CLI 설치 ────────────────────────────────────────────────────
install_gh() {
  export PATH="$INSTALL_PREFIX/bin:$PATH"
  if have gh; then
    ok "gh 이미 설치됨 ($(gh --version | head -n1))"
    return
  fi

  info "GitHub CLI 설치 중..."
  case "$PKG" in
    brew)
      brew install gh
      ;;
    apt)
      # apt 기본 저장소의 gh는 버전이 뒤처져 있어 공식 저장소를 등록한다.
      $SUDO apt-get update -qq
      $SUDO apt-get install -y curl ca-certificates gnupg
      $SUDO install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      $SUDO apt-get update -qq
      $SUDO apt-get install -y gh
      ;;
    dnf)
      $SUDO dnf install -y 'dnf-command(config-manager)'
      $SUDO dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
      $SUDO dnf install -y gh
      ;;
    yum)
      $SUDO yum install -y yum-utils
      $SUDO yum-config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
      $SUDO yum install -y gh
      ;;
    pacman)
      $SUDO pacman -Sy --noconfirm github-cli
      ;;
    macos-manual|linux-manual)
      install_gh_from_release
      ;;
  esac

  if have gh; then
    ok "gh 설치 완료 ($(gh --version | head -n1))"
  else
    warn "gh 설치에 실패했습니다. gh 없이 계속 진행합니다 (토큰 저장 단계는 건너뜁니다)."
  fi
}

# ── 3. python3 · node 준비 (macOS) ────────────────────────────────────
# 플러그인 훅·렌더가 `python3`·`node` 이름으로 호출한다(usage·핸드오프 훅은 node 18+).
# 훅은 Claude Desktop 이 띄운 Claude Code 안에서 돈다. Desktop 은 앱을 시작할 때 한 번
# 대화형 로그인 셸로 셸 프로필을 읽어 PATH 를 만들고(Desktop 로그 "[CCD] Resolved N
# login-shell env vars"), 그 PATH 가 훅까지 내려간다. 그래서 node 가 이 스크립트의 PATH 에만
# 있고 셸 프로필에 없으면 훅은 node 를 찾지 못한다 — 설치 후 판정은 로그인 셸 기준으로 한다.
#
# 이 단계는 실패해도 설치를 멈추지 않는다. node 없이도 플러그인 설치는 성공해 왔고, 이
# 단계 때문에 그 성공이 실패로 바뀌면 안 된다. 경고를 모아 두고 마지막에 다시 알린다.
# node 18+ 가 이미 있으면 아무것도 바꾸지 않는다. Linux 는 범위 밖이라 건너뛴다.
NODE_MIN_MAJOR=18
NODE_DIST_DIR="$INSTALL_PREFIX/share/nodejs"   # 공식 tarball 을 버전별로 푸는 곳
NODE_BIN_DIR=""            # 이번 실행에서 설치한 node 가 놓인 디렉토리
NEED_DESKTOP_RESTART=0     # node 를 설치했거나 셸 프로필 PATH 를 바꿨는지 — 떠 있는 Desktop 은 모른다
RUNTIME_WARNINGS=""        # 마지막에 다시 보여줄 경고 (줄바꿈 구분)
PROFILE_MARK="# added by contrl-setup"

add_runtime_warning() { RUNTIME_WARNINGS="${RUNTIME_WARNINGS}${1}"$'\n'; }

check_python3() {
  # CLT 가 없으면 /usr/bin/python3 는 실행하는 순간 설치 창을 띄우는 스텁이라, 그때는 실행하지
  # 않는다(git 을 다른 경로로 설치한 Mac). 기준 3.9 = CLT 의 python3.
  if { [[ "$(command -v python3 2>/dev/null)" == /usr/bin/python3 ]] && ! xcode-select -p >/dev/null 2>&1; } \
     || ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
    warn "python3 3.9 이상을 찾지 못했습니다. 슬라이드 렌더와 일부 자동 승인이 동작하지 않을 수 있습니다."
    add_runtime_warning "python3 3.9+ 없음 — 'xcode-select --install' 로 Command Line Tools 를 설치한 뒤 다시 실행해 주세요."
    return 0
  fi
  ok "python3 확인됨 ($(python3 --version 2>&1))"
}

# node 바이너리($1)의 major 버전. 없거나 실행이 안 되면 빈 값.
node_major_of() { "$1" -p "process.versions.node.split('.')[0]" 2>/dev/null || true; }

# 현재 PATH 의 node major. 없으면 빈 값.
node_major_here() {
  have node || return 0
  node_major_of node
}

# Desktop 과 같은 방식(대화형 로그인 셸)으로 셸 프로필을 읽었을 때 잡히는 node 를
# "major 경로" 한 줄로 출력한다(못 찾으면 빈 값). 셸을 못 띄우거나 10초 안에 끝나지 않으면 1.
# - setsid 로 터미널에서 떼어 낸다. 대화형 zsh 는 터미널의 foreground 그룹을 가져가고
#   돌려주지 않아서, 그대로 띄우면 뒤이은 토큰 입력(read)이 I/O 오류로 실패한다.
# - 프로필이 멈추는 경우를 대비한 시간 제한(macOS 에는 timeout 이 없다). 대화형 셸은 SIGTERM 을
#   무시하므로 프로세스 그룹째 KILL 해 프로필이 띄운 자식까지 끝낸다.
# - $(...) 안에서 불려 register_cleanup 이 EXIT 트랩에 닿지 않으므로 임시 디렉토리는 직접 지운다.
login_shell_node() {
  local sh="${SHELL:-/bin/zsh}" tmp pid i out=""
  [[ -x /usr/bin/perl ]] || return 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/contrl-shell.XXXXXX")" || return 1
  /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' \
    "$sh" -ilc 'p="$(command -v node)" && printf "CONTRL_NODE=%s %s\n" "$(node -p "process.versions.node.split(\".\")[0]")" "$p"' \
    </dev/null >"$tmp/out" 2>/dev/null &
  pid=$!
  for (( i = 0; i < 50; i++ )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    rm -rf "$tmp"
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  out="$(sed -n 's/^CONTRL_NODE=\([0-9][0-9]*\) /\1 /p' "$tmp/out" | tail -n1)"
  rm -rf "$tmp"
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# 로그인 셸이 읽는 프로필 파일. 고치지 않을 셸이면 1.
shell_profile_file() {
  local f
  case "$(basename "${SHELL:-}")" in
    zsh) printf '%s\n' "$HOME/.zprofile" ;;
    bash)
      # bash 로그인 셸은 .bash_profile → .bash_login → .profile 중 처음 있는 것 하나만 읽는다.
      # .bash_profile 을 새로 만들면 기존 .profile 이 더 이상 읽히지 않으므로 있는 파일에 쓴다.
      for f in .bash_profile .bash_login .profile; do
        [[ -f "$HOME/$f" ]] && { printf '%s\n' "$HOME/$f"; return 0; }
      done
      printf '%s\n' "$HOME/.bash_profile"
      ;;
    *) return 1 ;;
  esac
}

# 디렉토리를 셸 프로필의 PATH 맨 앞에 등록한다. 표식이 붙은 한 줄만 덧붙이고, 같은 줄이
# 이미 있으면 아무것도 하지 않는다. 기존 줄은 지우거나 고치지 않는다.
add_path_to_profile() {
  local dir="$1" file line
  line="export PATH=\"$dir:\$PATH\"  $PROFILE_MARK"
  if ! file="$(shell_profile_file)"; then
    warn "이 셸(${SHELL:-알 수 없음})의 설정 파일은 자동으로 고치지 않습니다. 아래 한 줄을 직접 추가하세요:
        export PATH=\"$dir:\$PATH\""
    return 1
  fi
  grep -qsF "$line" "$file" && return 0
  if ! printf '\n%s\n' "$line" >>"$file" 2>/dev/null; then
    warn "$file 에 PATH 를 등록하지 못했습니다. 아래 한 줄을 직접 추가하세요:
        export PATH=\"$dir:\$PATH\""
    return 1
  fi
  NEED_DESKTOP_RESTART=1
  ok "$file 에 PATH 등록: $dir"
}

# Desktop 이 읽는 로그인 셸에서 node 18+ 가 보이게 한다. 이미 보이면 아무것도 고치지 않는다.
ensure_node_visible_to_desktop() {
  local dir="$1" found="" checked=1
  found="$(login_shell_node)" || checked=0
  if [[ $checked -eq 1 && -n "$found" && "${found%% *}" -ge $NODE_MIN_MAJOR ]]; then
    return 0
  fi
  add_path_to_profile "$dir" || { add_runtime_warning "node 경로($dir)를 셸 설정에 등록하지 못함 — 위 안내대로 추가한 뒤 Claude 앱을 다시 시작하세요."; return 0; }

  found="" checked=1
  found="$(login_shell_node)" || checked=0
  if [[ $checked -eq 0 ]]; then
    warn "셸 설정을 읽는 데 시간이 너무 걸려 Claude 앱에서 node 가 보이는지 확인하지 못했습니다."
  elif [[ -z "$found" || "${found%% *}" -lt $NODE_MIN_MAJOR ]]; then
    # 예: nvm 이 ~/.zshrc 에서 오래된 기본 버전을 PATH 앞에 다시 넣는 경우
    warn "셸 설정에서 node 18 이상이 잡히지 않습니다 (잡힌 node: ${found:-없음}).
        셸 설정(~/.zshrc 등)이 다른 node 를 앞에 두고 있는지 확인해 주세요. (nvm 이면 'nvm alias default 22')"
    add_runtime_warning "셸 설정에서 node 18+ 가 잡히지 않음 (${found:-없음}) — 사용 기록·핸드오프 기능이 동작하지 않을 수 있습니다."
  fi
}

# 비교: 현재 macOS 가 $1.$2 이상인가
macos_at_least() {
  local v maj min
  v="$(sw_vers -productVersion 2>/dev/null)" || return 1
  maj="${v%%.*}"
  if [[ "$v" == *.* ]]; then min="${v#*.}"; min="${min%%.*}"; else min=0; fi
  [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1
  (( maj > $1 || (maj == $1 && min >= $2) ))
}

# nodejs.org 공식 tarball 을 $INSTALL_PREFIX/share/nodejs/<버전> 에 풀고 node 만
# $INSTALL_PREFIX/bin 에 링크한다(npm·npx 는 링크하지 않는다 — 다른 npm 을 가리지 않게).
# 실패하면 경고를 남기고 1. set -e 가 꺼지는 문맥(if/||)에서 호출되므로 단계마다 직접 확인한다.
install_node_from_release() {
  local arch major base sums line sum file name tmp actual dest link cur
  have curl || { warn "curl 이 없어 node 를 받지 못했습니다."; return 1; }
  case "$(uname -m)" in
    arm64)  arch="arm64" ;;
    x86_64) arch="x64" ;;
    *) warn "지원하지 않는 아키텍처라 node 를 설치하지 못했습니다: $(uname -m)"; return 1 ;;
  esac
  # 지원 macOS: Node 24 는 13.5+, Node 22 는 11+ (각 버전 BUILDING.md 의 플랫폼 표)
  if   macos_at_least 13 5; then major=24
  elif macos_at_least 11 0; then major=22
  else
    warn "이 macOS($(sw_vers -productVersion 2>/dev/null))에서 동작하는 Node.js 공식 빌드가 없습니다."
    return 1
  fi

  base="https://nodejs.org/dist/latest-v${major}.x"
  info "Node.js ${major} 최신 버전 확인 중..."
  sums="$(curl -fsSL "$base/SHASUMS256.txt")" || { warn "Node.js 버전 목록을 받지 못했습니다: $base"; return 1; }
  line="$(printf '%s\n' "$sums" | grep -E "  node-v[0-9.]+-darwin-${arch}\.tar\.gz\$" | head -n1)"
  [[ -n "$line" ]] || { warn "Node.js 설치 파일(darwin-${arch})을 찾지 못했습니다."; return 1; }
  sum="${line%% *}"; file="${line##* }"; name="${file%.tar.gz}"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/node-install.XXXXXX")" || return 1
  register_cleanup "$tmp"
  info "${name} 다운로드 중..."
  curl -fsSL "$base/$file" -o "$tmp/$file" || { warn "Node.js 다운로드 실패: $base/$file"; return 1; }
  actual="$(shasum -a 256 "$tmp/$file" | awk '{print $1}')"
  [[ "$actual" == "$sum" ]] || { warn "Node.js 파일 검증(SHA-256)에 실패했습니다."; return 1; }
  tar -xzf "$tmp/$file" -C "$tmp" || { warn "Node.js 압축 해제 실패"; return 1; }
  [[ -x "$tmp/$name/bin/node" ]] || { warn "압축 해제된 node 를 찾지 못했습니다."; return 1; }

  dest="$INSTALL_PREFIX/share/nodejs"
  link="$INSTALL_PREFIX/bin/node"
  # 이 스크립트가 만든 링크만 바꾼다 — 유저가 직접 둔 node 는 덮어쓰지 않는다.
  if [[ -e "$link" || -L "$link" ]]; then
    cur="$(readlink "$link" 2>/dev/null || true)"
    if [[ "$cur" != "$dest"/* ]]; then
      warn "$link 에 다른 node 가 있어 덮어쓰지 않았습니다. 지우거나 18 이상으로 바꾼 뒤 다시 실행해 주세요."
      return 1
    fi
  fi
  mkdir -p "$dest" "$INSTALL_PREFIX/bin" || return 1
  rm -rf "${dest:?}/$name"
  mv "$tmp/$name" "$dest/$name" || { warn "Node.js 를 $dest 로 옮기지 못했습니다."; return 1; }
  ln -sfn "$dest/$name/bin/node" "$link" || { warn "$link 링크를 만들지 못했습니다."; return 1; }
  NODE_BIN_DIR="$INSTALL_PREFIX/bin"
}

install_node() {
  [[ "$OS" == "Darwin" ]] || return 0
  local major
  major="$(node_major_here)"
  if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= NODE_MIN_MAJOR )); then
    ok "node 이미 설치됨 ($(node --version))"
    # 지난 실행이 설치한 node 인데 PATH 등록이 안 됐던 경우만 다시 등록을 시도한다.
    if [[ "$(readlink "$INSTALL_PREFIX/bin/node" 2>/dev/null || true)" == "$INSTALL_PREFIX/share/nodejs/"* \
          && "$(command -v node)" == "$INSTALL_PREFIX/bin/node" ]]; then
      ensure_node_visible_to_desktop "$INSTALL_PREFIX/bin"
    fi
    return 0
  fi
  if [[ -n "$major" ]]; then
    info "node $(node --version 2>/dev/null) 는 18 미만이라 새 버전을 함께 설치합니다 (기존 node 는 지우지 않습니다)."
  fi

  info "Node.js 설치 중..."
  NODE_BIN_DIR=""
  if [[ "$PKG" == "brew" ]]; then
    # 종료 코드만 믿지 않는다 — 다른 node(예: node@16)와 링크가 충돌해도 0 이 나올 수 있다.
    local brew_bin brew_major=""
    brew_bin="$(brew --prefix 2>/dev/null || true)/bin"
    if brew install node && [[ -x "$brew_bin/node" ]]; then
      brew_major="$("$brew_bin/node" -p "process.versions.node.split('.')[0]" 2>/dev/null || true)"
    fi
    if [[ "$brew_major" =~ ^[0-9]+$ ]] && (( brew_major >= NODE_MIN_MAJOR )); then
      NODE_BIN_DIR="$brew_bin"
    else
      warn "brew 로 node 18+ 를 준비하지 못했습니다. 공식 배포판으로 다시 시도합니다."
    fi
  fi
  if [[ -z "$NODE_BIN_DIR" ]] && ! install_node_from_release; then
    add_runtime_warning "node 18+ 설치 실패 — https://nodejs.org/ 에서 LTS 를 설치한 뒤 Claude 앱을 다시 시작하세요. (없으면 사용 기록·핸드오프 기능이 동작하지 않습니다)"
    return 0
  fi

  export PATH="$NODE_BIN_DIR:$PATH"
  hash -r
  NEED_DESKTOP_RESTART=1
  ok "node 설치 완료 ($("$NODE_BIN_DIR/node" --version 2>/dev/null))"
  ensure_node_visible_to_desktop "$NODE_BIN_DIR"
}

prepare_runtimes() {
  [[ "$OS" == "Darwin" ]] || return 0
  check_python3
  install_node
}

# ── 4. Claude Code 설치 ───────────────────────────────────────────────
install_claude() {
  # 공식 네이티브 설치는 $HOME/.local/bin 에 놓인다. 현재 셸 PATH에 없을 수
  # 있으므로 판정 전에 먼저 추가한다.
  export PATH="$HOME/.local/bin:$PATH"

  if have claude && claude --version >/dev/null 2>&1; then
    ok "Claude Code 이미 설치됨 ($(claude --version))"
    return
  fi

  have curl || die "curl이 필요합니다."
  info "Claude Code 설치 중..."
  # 공식 설치 스크립트 — 자동 업데이트되는 네이티브 빌드를 ~/.local/bin 에 설치한다.
  curl -fsSL https://claude.ai/install.sh | bash || die "Claude Code 설치 실패"

  have claude && claude --version >/dev/null 2>&1 \
    || die "Claude Code 설치 후에도 claude 명령을 찾지 못했습니다. 새 터미널에서 다시 실행해 보세요."
  ok "Claude Code 설치 완료 ($(claude --version))"
}

# ── 4. 토큰 입력 ──────────────────────────────────────────────────────
# 브라우저를 직접 연다 — 터미널에서 긴 주소를 복사해 옮기는 단계가 빠진다.
# GUI가 없거나(SSH, 컨테이너) 열기에 실패하면 주소를 그대로 보여준다.
open_url() {
  local url="$1"
  case "$(uname -s)" in
    Darwin) open "$url" >/dev/null 2>&1 ;;
    *)      [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && have xdg-open && xdg-open "$url" >/dev/null 2>&1 ;;
  esac
}

show_token_page() {
  if open_url "$TOKEN_URL"; then
    info "브라우저에 토큰 발급 페이지를 열었습니다. 토큰을 만든 뒤 값을 복사하세요. (화면의 초록색 버튼)"
    printf '        열리지 않으면 직접 접속: %s\n' "$TOKEN_URL"
  else
    info "아래 주소에서 토큰을 만든 뒤 값을 복사하세요. (화면의 초록색 버튼)"
    printf '        %s\n' "$TOKEN_URL"
  fi
}

# 프롬프트는 stderr로 보낸다 — 이 함수의 stdout은 호출 측이 토큰 값으로 받는다.
read_token() {
  local t=""
  [[ -t 0 ]] || die "PAT를 입력받을 수 없습니다(비대화형 실행). 아래 형태로 실행하세요:
        bash -c \"\$(curl -fsSL $SCRIPT_URL)\""
  printf 'GitHub 토큰을 붙여넣고 Enter (입력은 화면에 표시되지 않습니다): ' >&2
  read -rs t
  printf '\n' >&2
  printf '%s' "$t"
}

# 실패해도 멈추지 않는다 — 저장소가 공개이거나 다른 credential helper가
# 이미 있으면 플러그인 설치는 그대로 성공한다. 판정은 install_plugin이 한다.
setup_git_credential() {
  have gh || return 0
  gh auth setup-git --hostname github.com >/dev/null 2>&1 \
    || warn "git 자격증명 연결에 실패했습니다. 그대로 플러그인 설치를 시도합니다."
}

# ── 5. 플러그인 설치 (저장소 접근 확인 겸용) ──────────────────────────
# GitHub는 권한 없는 private 저장소를 404로 숨기므로 스코프 누락과 초대 미수락을
# 구분할 수 없다. 그래서 둘 다 안내한다 — 한쪽만 지목하면 나머지 절반의
# 사용자를 엉뚱한 곳으로 보내게 된다.
show_access_failure_causes() {
  warn "저장소에 접근하지 못했습니다. 원인은 보통 둘 중 하나입니다:"
  printf '        1) 토큰을 만들 때 %s 항목을 체크하지 않음\n' "'repo'"
  printf '        2) 초대 메일을 아직 수락하지 않음 (수락한 뒤 다시 시도)\n'
}

# marketplace add/update 가 private 저장소를 clone하므로 별도의 검증 clone이
# 필요 없다 — 여기가 실패하면 곧 저장소 접근 실패다.
install_plugin() {
  # owner/repo 축약형은 기본이 SSH clone 이다. 이 스크립트는 PAT(HTTPS)만
  # 구성하므로 HTTPS를 강제하고, 자격증명이 통하지 않을 때 git이 사용자명을
  # 되묻고 멈추는 것도 막는다.
  export CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1
  export GIT_TERMINAL_PROMPT=0

  info "CONTRL 플러그인 설치 중..."
  if claude plugin marketplace list 2>/dev/null | grep -q "$MARKETPLACE"; then
    # 재시도(새 토큰) 경로 — 이미 등록된 marketplace를 새 자격증명으로 갱신
    claude plugin marketplace update "$MARKETPLACE" >/dev/null 2>&1 || return 1
  else
    claude plugin marketplace add "$REPO" >/dev/null 2>&1 || return 1
  fi

  claude plugin install "$PLUGIN@$MARKETPLACE" --scope user >/dev/null 2>&1 || return 1
  claude plugin list 2>/dev/null | grep -q "$PLUGIN@$MARKETPLACE" \
    || return 1

  ok "CONTRL 플러그인 설치 완료 ($PLUGIN@$MARKETPLACE)"
}

# 저장된 인증으로 먼저 시도하고, 실패하면 토큰을 다시 받아 최대 MAX_ATTEMPTS회 재시도한다.
# 저장된 토큰이 '유효하지만 이 저장소에는 권한이 없는' 상태여도 gh auth status는 성공하므로,
# 인증 여부만 보고 건너뛰면 새 토큰을 만들어도 반영되지 않는 상태에 갇힌다.
# gh 로그인·credential helper 연결은 실패해도 멈추지 않는다 — 저장소가 공개이거나
# 자격증명이 다른 경로로 이미 있으면 설치는 그대로 통과하기 때문이다.
# 성공/실패 판정은 오직 install_plugin 결과로만 한다.
ensure_access() {
  local attempt=0 token=""

  if [[ "$SKIP_VERIFY" -eq 1 ]]; then
    warn "CONTRL_SKIP_VERIFY: 플러그인 설치 생략"
    return
  fi

  if [[ -z "${GITHUB_PAT:-}" ]] && have gh && gh auth status >/dev/null 2>&1; then
    ok "GitHub 인증 이미 구성됨 (사용자: $(gh api user --jq .login 2>/dev/null || echo unknown))"
    setup_git_credential
    if install_plugin; then return; fi
    show_access_failure_causes
    info "새 토큰으로 다시 시도합니다."
  fi

  while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
    attempt=$((attempt + 1))

    if [[ $attempt -eq 1 && -n "${GITHUB_PAT:-}" ]]; then
      token="$GITHUB_PAT"
    else
      show_token_page
      token="$(read_token)"
    fi

    if [[ -z "$token" ]]; then
      warn "빈 토큰입니다. ($attempt/$MAX_ATTEMPTS)"
      continue
    fi

    if have gh; then
      info "토큰 저장 중..."
      if printf '%s' "$token" | gh auth login --hostname github.com --git-protocol https --with-token >/dev/null 2>&1; then
        ok "토큰 저장 완료 (사용자: $(gh api user --jq .login 2>/dev/null || echo unknown))"
        setup_git_credential
      else
        warn "gh 토큰 저장에 실패했습니다. 그대로 플러그인 설치를 시도합니다. ($attempt/$MAX_ATTEMPTS)"
      fi
    else
      warn "gh가 없어 토큰을 저장하지 못합니다. 그대로 플러그인 설치를 시도합니다."
    fi
    token=""

    if install_plugin; then return; fi

    show_access_failure_causes
    if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
      info "다시 시도합니다. ($attempt/$MAX_ATTEMPTS)"
    fi
  done

  die "${MAX_ATTEMPTS}회 모두 실패했습니다. 위 두 가지를 확인한 뒤 같은 명령어를 다시 실행하거나,
        화면에 나온 메시지를 그대로 담당자에게 전달해 주세요."
}

# ── 5. 마무리 ─────────────────────────────────────────────────────────
# 설치가 끝나면 Claude Desktop의 Claude Code 화면을 바로 띄우고, 입력창에
# "/contrl:setup 한국어로 설치 진행" 을 채워 둔다(전송은 하지 않는다 — Enter는 사용자 몫).
# claude:// 딥링크는 Desktop 앱이 등록하므로, 앱이 없거나 GUI가 아니면
# (SSH, 컨테이너, Linux) 열리지 않는다.
#
# 이 단계는 편의 기능이다. 어떤 이유로 실패해도 설치 결과에는 영향이 없어야
# 하므로, 함수는 절대 스크립트를 중단시키지 않고 0/1만 돌려준다. 호출 측은
# 성공 메시지를 먼저 출력한 뒤 이 함수를 부르고, 실패하면 직접 열라는 안내로
# 대신한다. 이미 실행 중이면 새로 띄우지 않고 앞으로 가져온다.
# q= 값은 URL 인코딩된 "/contrl:setup 한국어로 설치 진행" (한글은 UTF-8 퍼센트 인코딩).
#
# 검증 상태: macOS에서만 실제 확인했다(Desktop 1.46388.1). Windows는 install.ps1 참고.
SETUP_DEEPLINK='claude://code/new?q=%2Fcontrl%3Asetup%20%ED%95%9C%EA%B5%AD%EC%96%B4%EB%A1%9C%20%EC%84%A4%EC%B9%98%20%EC%A7%84%ED%96%89&source=url_external'

open_claude_desktop() {
  # 서브셸에서 돌려 set -e·trap·환경 변화가 바깥으로 새지 않게 한다.
  (
    set +e
    case "$(uname -s 2>/dev/null)" in
      Darwin)
        have open || exit 1
        open "$SETUP_DEEPLINK" >/dev/null 2>&1
        ;;
      *) exit 1 ;;   # Linux는 공식 Desktop 앱이 없다
    esac
  ) 2>/dev/null || return 1
  return 0
}

# ── Desktop 재시작 (macOS) ────────────────────────────────────────────
# Desktop 은 셸 PATH 를 앱을 시작할 때 한 번만 읽는다. 이번 실행에서 node 를 설치했거나
# PATH 를 등록했는데 Desktop 이 이미 떠 있으면, 그 Desktop(과 훅)은 새 node 를 못 본다.
# 딥링크는 떠 있는 창을 앞으로 가져오기만 하므로 재시작을 제안한다.
#
# 프로세스 이름(대소문자 구분)으로 찾는다. Desktop 본체만 "Claude" 이고, 터미널의 Claude Code
# CLI 와 Desktop 내장 Claude Code 는 "claude", Helper 들은 "Claude Helper …" 라 잡히지 않는다.
# 내 계정의 프로세스만 본다 — 빠른 사용자 전환 중인 다른 계정의 Desktop 은 끌 수도 없고 끄면 안 된다.
DESKTOP_UID="$(id -u)"
desktop_pids() { pgrep -U "$DESKTOP_UID" -x Claude 2>/dev/null || true; }
desktop_running() { [[ -n "$(desktop_pids)" ]]; }

# 이 스크립트가 Desktop 안(Claude Code 세션의 터미널 등)에서 돌고 있으면 재시작이 스크립트 자신을 끝낸다.
running_inside_desktop() {
  local pids p
  pids=" $(desktop_pids | tr '\n' ' ') "
  p=$$
  while [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )); do
    [[ "$pids" == *" $p "* ]] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

wait_desktop_exit() {
  local i n=$(( $1 * 5 ))
  for (( i = 0; i < n; i++ )); do
    desktop_running || return 0
    sleep 0.2
  done
  ! desktop_running
}

# SIGTERM 은 Electron 에서 ⌘Q 와 같은 정상 종료다. osascript(quit app)는 터미널에 자동화
# 권한 창을 띄울 수 있어 쓰지 않는다. 끝까지 안 꺼지면 강제 종료하고, 꺼진 것을 확인한 뒤에만
# 0 을 돌려준다 — 종료 중인 인스턴스가 딥링크를 받으면 프리필이 사라진다.
restart_claude_desktop() {
  (
    set +e
    pkill -TERM -U "$DESKTOP_UID" -x Claude
    wait_desktop_exit 10 && exit 0
    pkill -KILL -U "$DESKTOP_UID" -x Claude
    wait_desktop_exit 3
  ) 2>/dev/null
}

show_restart_guidance() {
  info "Claude Desktop을 완전히 종료(⌘Q)한 뒤 다시 열어 주세요. 그래야 방금 설치한 node 를 앱이 인식합니다."
  info "다시 연 뒤 Claude Code 입력창에 '/contrl:setup 한국어로 설치 진행' 을 입력해 실행하세요."
}

# 0: 딥링크로 이어가도 된다(재시작이 필요 없거나 재시작함)  1: 재시작 안내를 이미 출력함
offer_desktop_restart() {
  local ans=""
  [[ "$OS" == "Darwin" && "$NEED_DESKTOP_RESTART" -eq 1 ]] || return 0
  desktop_running || return 0
  if [[ ! -t 0 ]] || running_inside_desktop; then
    show_restart_guidance
    return 1
  fi
  # 기본값은 Y — 재시작해야 이번 설치가 효과를 내므로 Enter 만 눌러도 진행한다.
  # 작업이 끊길 수 있다는 점은 질문에 적어 두고, n 일 때만 직접 재시작 안내로 돌린다.
  # 기본값이 Y 라서, 설치를 기다리며 미리 눌러 둔 Enter 가 그대로 동의가 되지 않도록
  # 묻기 직전에 터미널 입력 버퍼를 비운다.
  /usr/bin/perl -MPOSIX -e 'POSIX::tcflush(0, POSIX::TCIFLUSH())' 2>/dev/null || true
  printf '\n'
  info "Claude Desktop이 실행 중입니다. 방금 설치한 node 를 앱이 인식하려면 다시 시작해야 합니다."
  printf '        진행 중인 Claude 작업이 있다면 끊어집니다. 지금 Claude를 다시 시작할까요? [Y/n] '
  read -r ans || ans="n"
  case "$ans" in
    [nN]|[nN][oO]) show_restart_guidance; return 1 ;;
  esac
  info "Claude Desktop을 다시 시작합니다..."
  restart_claude_desktop && return 0
  warn "Claude Desktop을 종료하지 못했습니다."
  show_restart_guidance
  return 1
}

# ── 실행 ──────────────────────────────────────────────────────────────
install_git
install_gh
prepare_runtimes
install_claude
ensure_access

printf '\n'
ok "모든 단계 완료. CONTRL 플러그인이 준비돼 있습니다."
if [[ -n "$RUNTIME_WARNINGS" ]]; then
  warn "아래 항목은 준비되지 않았습니다 (플러그인은 설치됐습니다):"
  printf '%s' "$RUNTIME_WARNINGS" | while IFS= read -r line; do printf '        - %s\n' "$line"; done
  printf '        회사 보안 정책이나 네트워크 환경 때문에 설치·사용 기록 전송이 막혔을 수도 있습니다.\n'
fi

# 아래는 실패해도 무방한 편의 단계 — 어떤 결과든 안내 문구만 달라진다.
if offer_desktop_restart; then
  if open_claude_desktop; then
    info "Claude Desktop을 열었습니다. 입력창에 채워진 '/contrl:setup 한국어로 설치 진행' 을 Enter로 실행하세요."
  else
    info "Claude Desktop을 직접 연 뒤, Claude Code 입력창에 '/contrl:setup 한국어로 설치 진행' 을 입력해 실행하세요."
  fi
fi
