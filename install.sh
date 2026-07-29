#!/usr/bin/env bash
#
# install.sh — CONTRL 설치 (macOS / Linux)
#   1. git 설치
#   2. GitHub CLI(gh) 설치
#   3. GitHub PAT 저장 + git credential helper 연결
#   4. 저장소 접근 확인 — 실패하면 원인을 안내하고 최대 3회까지 토큰 재입력
#
# Homebrew는 선택 사항이다. 없으면:
#   - git : Xcode Command Line Tools 로 설치
#   - gh  : GitHub 공식 릴리스 바이너리를 $INSTALL_PREFIX 에 설치 (sudo 불필요)
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
#   CONTRL_SKIP_VERIFY   저장소 접근 확인 생략
#   CONTRL_NO_BREW       brew가 있어도 릴리스 바이너리 사용
#   INSTALL_PREFIX       brew 없이 gh를 설치할 위치 (기본: $HOME/.local)
#

set -euo pipefail

REPO="cliwant/contrl-harness"
INSTALL_PREFIX="${INSTALL_PREFIX:-$HOME/.local}"
MAX_ATTEMPTS=3
SCRIPT_URL="https://raw.githubusercontent.com/cliwant/contrl-setup/main/install.sh"
# scopes 파라미터로 repo 체크박스를 미리 채워 둔다 — 스코프 누락이 접근 실패의 절반이다.
TOKEN_URL="https://github.com/settings/tokens/new?scopes=repo&description=CONTRL%20harness"

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
  if ! grep -qs "$INSTALL_PREFIX/bin" "${HOME}/.zshrc" "${HOME}/.bashrc" 2>/dev/null; then
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

  have gh || die "gh 설치 실패"
  ok "gh 설치 완료 ($(gh --version | head -n1))"
}

# ── 3. 토큰 입력 ──────────────────────────────────────────────────────
open_token_page() {
  info "토큰 발급 페이지를 엽니다. 화면의 초록색 버튼을 눌러 토큰을 만든 뒤 값을 복사하세요."
  printf '        %s\n' "$TOKEN_URL"
  if   [[ "$OS" == "Darwin" ]] && have open; then open "$TOKEN_URL" >/dev/null 2>&1 || true
  elif have xdg-open;                        then xdg-open "$TOKEN_URL" >/dev/null 2>&1 || true
  else warn "브라우저를 자동으로 열지 못했습니다. 위 주소를 직접 열어 주세요."
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

setup_git_credential() {
  gh auth setup-git --hostname github.com >/dev/null 2>&1 \
    || die "git 자격증명 연결에 실패했습니다."
}

# ── 4. 저장소 접근 확인 ───────────────────────────────────────────────
# GitHub는 권한 없는 private 저장소를 404로 숨기므로 스코프 누락과 초대 미수락을
# 구분할 수 없다. 그래서 둘 다 안내한다 — 한쪽만 지목하면 나머지 절반의
# 사용자를 엉뚱한 곳으로 보내게 된다.
show_access_failure_causes() {
  warn "저장소에 접근하지 못했습니다. 원인은 보통 둘 중 하나입니다:"
  printf '        1) 토큰을 만들 때 %s 항목을 체크하지 않음\n' "'repo'"
  printf '        2) 초대 메일을 아직 수락하지 않음 (수락한 뒤 다시 시도)\n'
}

verify_access() {
  local tmpdir rc=0
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/contrl-verify.XXXXXX")"
  register_cleanup "$tmpdir"

  info "저장소 접근 확인 중..."
  # 자격증명이 통하지 않을 때 git이 사용자명을 되묻고 멈추는 것을 막는다.
  if GIT_TERMINAL_PROMPT=0 git clone --depth 1 --quiet \
       "https://github.com/$REPO.git" "$tmpdir/repo" >/dev/null 2>&1; then
    ok "저장소 접근 확인 (HEAD: $(git -C "$tmpdir/repo" rev-parse --short HEAD))"
  else
    rc=1
  fi

  rm -rf "$tmpdir"
  return $rc
}

# 저장된 인증으로 먼저 시도하고, 실패하면 토큰을 다시 받아 최대 MAX_ATTEMPTS회 재시도한다.
# 저장된 토큰이 '유효하지만 이 저장소에는 권한이 없는' 상태여도 gh auth status는 성공하므로,
# 인증 여부만 보고 건너뛰면 새 토큰을 만들어도 반영되지 않는 상태에 갇힌다.
ensure_access() {
  local attempt=0 token=""

  if [[ -z "${GITHUB_PAT:-}" ]] && gh auth status >/dev/null 2>&1; then
    ok "GitHub 인증 이미 구성됨 (사용자: $(gh api user --jq .login 2>/dev/null || echo unknown))"
    setup_git_credential
    if [[ "$SKIP_VERIFY" -eq 1 ]]; then
      warn "CONTRL_SKIP_VERIFY: 저장소 접근 확인 생략"
      return
    fi
    if verify_access; then return; fi
    show_access_failure_causes
    info "새 토큰으로 다시 시도합니다."
  fi

  while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
    attempt=$((attempt + 1))

    if [[ $attempt -eq 1 && -n "${GITHUB_PAT:-}" ]]; then
      token="$GITHUB_PAT"
    else
      open_token_page
      token="$(read_token)"
    fi

    if [[ -z "$token" ]]; then
      warn "빈 토큰입니다. ($attempt/$MAX_ATTEMPTS)"
      continue
    fi

    info "토큰 저장 중..."
    if ! printf '%s' "$token" | gh auth login --hostname github.com --git-protocol https --with-token >/dev/null 2>&1; then
      token=""
      warn "토큰이 유효하지 않습니다. 값을 다시 확인해 주세요. ($attempt/$MAX_ATTEMPTS)"
      continue
    fi
    token=""
    ok "토큰 저장 완료 (사용자: $(gh api user --jq .login 2>/dev/null || echo unknown))"
    setup_git_credential

    if [[ "$SKIP_VERIFY" -eq 1 ]]; then
      warn "CONTRL_SKIP_VERIFY: 저장소 접근 확인 생략"
      return
    fi
    if verify_access; then return; fi

    show_access_failure_causes
    if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
      info "다시 시도합니다. ($attempt/$MAX_ATTEMPTS)"
    fi
  done

  die "${MAX_ATTEMPTS}회 모두 실패했습니다. 위 두 가지를 확인한 뒤 같은 명령어를 다시 실행하거나,
        화면에 나온 메시지를 그대로 담당자에게 전달해 주세요."
}

# ── 실행 ──────────────────────────────────────────────────────────────
install_git
install_gh
ensure_access

printf '\n'
ok "모든 단계 완료. Claude Desktop을 열어 주세요."
