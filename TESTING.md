# 설치 스크립트 검증 목록

`install.sh` / `install.ps1` 을 고객에게 배포하기 전에 확인할 항목이다.
성공 경로는 한 번 되면 그만이지만 실패 경로는 안내가 나쁘면 그대로 지원 요청이 되므로, 실패 경로를 성공 경로와 같은 비중으로 검증한다.

## 사전 준비

**테스트용 GitHub 계정 1개.** 본인 계정은 이미 `cliwant/contrl-harness` 접근 권한이 있어서 실패 경로를 재현할 수 없다. outside collaborator 초대와 해제를 반복할 수 있는 별도 계정이 필요하다.

**토큰 2종을 미리 발급해 둔다.** classic token(`https://github.com/settings/tokens/new`) 기준으로 ① `repo` 스코프를 체크한 것 ② 아무 스코프도 체크하지 않은 것. ②가 스코프 실패 경로 재현에 쓰인다.

**상태 초기화 절차.** 각 테스트는 이전 테스트의 잔재가 없는 상태에서 시작해야 한다. 특히 T5는 저장된 인증이 남아 있으면 재현 자체가 안 된다.

macOS/Linux:

```
gh auth logout --hostname github.com
rm -f ~/.config/gh/hosts.yml
git config --global --unset-all credential.https://github.com.helper
rm -rf ~/.local/bin/gh
```

Windows:

```
gh auth logout --hostname github.com
Remove-Item "$env:APPDATA\GitHub CLI\hosts.yml" -ErrorAction SilentlyContinue
git config --global --unset-all credential.https://github.com.helper
```

Windows는 자격 증명 관리자(제어판 → 자격 증명 관리자 → Windows 자격 증명)에 남은 `git:https://github.com` 항목도 지운다.

## 필수 — 통과 못 하면 배포하지 않는다

### T1 · 파이프 실행에서 PAT 프롬프트가 뜨는가 (macOS)

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cliwant/contrl-setup/main/install.sh)"
```

기대: PAT 입력 프롬프트가 뜨고, 입력한 문자가 화면에 표시되지 않는다.

이 항목이 있는 이유는 `curl … | bash` 형태에서는 bash의 stdin이 터미널이 아니라 curl의 파이프가 되어 프롬프트에 도달하기 전에 죽기 때문이다. `bash -c "$(…)"` 는 스크립트를 커맨드 치환으로 먼저 받으므로 stdin이 터미널로 유지된다. 배포 명령어를 바꾸게 되면 이 항목부터 다시 확인한다.

### T2 · PowerShell 5.1에서 한글이 깨지지 않는가 (Windows)

Windows PowerShell 5.1(PowerShell 7이 아니라 시작 메뉴의 "Windows PowerShell")에서:

```
irm https://raw.githubusercontent.com/cliwant/contrl-setup/main/install.ps1 | iex
```

기대: 모든 `[INFO]`/`[ OK ]`/`[FAIL]` 메시지의 한글이 정상 출력된다.

파일을 디스크에서 읽을 때와 달리 이 경로는 HTTP 응답 헤더의 charset으로 디코딩되므로 BOM 규칙이 적용되지 않는다. 깨지면 고객이 보는 첫 화면이 통째로 물음표가 되므로 타협하지 않는다.

### T3 · 초대되지 않은 계정의 실패 안내 (macOS 또는 Windows)

테스트 계정을 outside collaborator에서 제거한 상태에서 `repo` 스코프 토큰으로 실행한다.

기대: clone 검증에서 실패하고, 실패 메시지가 원인 후보를 모두 제시한다 — ① 토큰에 `repo` 스코프 미체크 ② 초대 미수락. GitHub는 권한 없는 private repo를 404로 숨기므로 스크립트는 둘을 구분할 수 없다. 한쪽만 지목하면 나머지 절반의 유저를 엉뚱한 곳으로 보낸다.

### T4 · 스코프 없는 토큰의 3회 재입력 루프

스코프 없는 토큰을 입력한다.

기대: `gh auth login` 은 성공하지만(토큰 자체는 유효하다) clone 검증에서 실패하고, 그 자리에서 원인 안내 + 토큰 발급 페이지 재오픈 + PAT 재입력을 제안한다. 2회차에 올바른 토큰을 넣으면 성공한다. 3회 모두 실패하면 안내 문구와 함께 종료한다.

### T5 · 잘못된 토큰이 저장된 상태에서 재실행

T4에서 3회 실패로 종료된 직후(= 잘못된 토큰이 저장소에 남아 있는 상태), 같은 명령어를 처음부터 다시 실행한다.

기대: "인증 이미 구성됨"으로 넘어가지 않고 PAT를 다시 물어본다.

이 항목이 가장 중요하다. 저장된 토큰이 유효하기만 하면 `gh auth status` 가 성공하므로, 인증 여부만 보고 건너뛰면 유저는 새 토큰을 만들어도 스크립트가 받아주지 않는 무한 루프에 갇힌다. 탈출구가 `GITHUB_PAT` 환경변수뿐인 상태로 남기지 않는다.

## 권장 — 배포는 가능하되 확인해 두면 좋다

### T6 · Claude Desktop 세션에서의 실행 환경

Claude Desktop을 열고 세션 안에서 `which gh`(Windows는 `Get-Command gh`)와 `git clone https://github.com/cliwant/contrl-harness.git` 을 실행한다.

기대: 둘 다 성공한다.

터미널에서만 확인하면 이 항목을 놓친다. 설치를 검증하는 환경과 제품이 실제로 도는 환경이 다르기 때문이다. harness는 런타임에 `gh` 를 호출하므로(유저 식별, 위키 repo 탐색, PR 생성) Desktop이 띄우는 프로세스에서 `gh` 가 보이지 않으면 설치는 초록불로 끝나고 파이프라인 중간에 원인 불명으로 실패한다.

### T7 · Homebrew 없는 macOS 경로

macOS에 새 사용자 계정을 만들어 로그인한 뒤 실행하거나, 기존 계정에서 `--no-brew` 로 실행한다.

기대: gh가 `$HOME/.local/bin` 에 설치되고, 그 경로가 PATH에 없으면 안내가 뜬다. 안내만 띄우고 끝나면 고객은 그 줄을 읽지 않는다는 점을 감안해 결과를 판단한다.

### T8 · 전 과정 성공 경로 (happy path)

깨끗한 상태 + 초대된 계정 + `repo` 스코프 토큰으로 처음부터 끝까지 실행한다.

기대: git 설치 → gh 설치 → PAT 저장 → clone 검증까지 전부 통과하고, 마지막 출력이 다음 단계를 그대로 복사할 수 있는 형태로 안내한다.

```
모든 단계 완료. Claude Desktop을 열고 아래를 차례로 입력하세요.
  /plugin marketplace add cliwant/contrl-harness
  /plugin install contrl@contrl-harness
```

## 검증하지 않는 것

**환경변수 스위치(`CONTRL_SKIP_VERIFY`).** 개발용이며 고객 경로에서 쓰이지 않는다. 동작하지 않아도 고객 영향이 없다.

**winget 없는 구형 Windows.** winget 부재는 명확한 메시지로 즉시 종료되므로 별도 재현이 불필요하다.
