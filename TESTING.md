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
# node 시나리오(T8-m)용 — 스크립트가 설치한 node 와 셸 프로필 등록 줄
rm -rf ~/.local/bin/node ~/.local/share/nodejs
sed -i '' '/# added by contrl-setup$/d' ~/.zprofile ~/.bash_profile ~/.profile 2>/dev/null
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

기대: 플러그인 설치(marketplace add) 단계에서 실패하고, 실패 메시지가 원인 후보를 모두 제시한다 — ① 토큰에 `repo` 스코프 미체크 ② 초대 미수락. GitHub는 권한 없는 private repo를 404로 숨기므로 스크립트는 둘을 구분할 수 없다. 한쪽만 지목하면 나머지 절반의 유저를 엉뚱한 곳으로 보낸다.

### T4 · 스코프 없는 토큰의 3회 재입력 루프

스코프 없는 토큰을 입력한다.

기대: `gh auth login` 은 성공하지만(토큰 자체는 유효하다) 플러그인 설치에서 실패하고, 그 자리에서 원인 안내 + 토큰 발급 주소 재표시 + PAT 재입력을 제안한다. 2회차에 올바른 토큰을 넣으면 성공한다. 이때 1회차 실패로 marketplace가 반쯤 등록된 상태여도 재시도 경로(`marketplace update`)가 새 자격증명으로 이어받아야 한다. 3회 모두 실패하면 안내 문구와 함께 종료한다.

### T4-1 · gh 없이 / gh 로그인 실패 상태에서 진행

`gh` 를 PATH에서 제거한 상태(또는 `gh auth login` 이 실패하도록 네트워크를 막은 상태)에서 실행한다.

기대: 확인 순서(로그인 확인 → 토큰 입력 → 플러그인 설치)는 그대로다. 다만 gh 설치·토큰 저장·credential helper 연결 실패는 모두 경고로만 출력되고 곧바로 플러그인 설치로 넘어간다. 저장소가 공개이거나 git 자격증명이 다른 경로(osxkeychain, Git Credential Manager 등)로 이미 있으면 설치가 성공하고, 없으면 원인 안내 후 토큰 재입력 루프로 이어진다. 어느 경우에도 gh 단계에서 스크립트가 멈추지 않는다.

### T5 · 잘못된 토큰이 저장된 상태에서 재실행

T4에서 3회 실패로 종료된 직후(= 잘못된 토큰이 저장소에 남아 있는 상태), 같은 명령어를 처음부터 다시 실행한다.

기대: "인증 이미 구성됨"으로 넘어가지 않고 PAT를 다시 물어본다.

이 항목이 가장 중요하다. 저장된 토큰이 유효하기만 하면 `gh auth status` 가 성공하므로, 인증 여부만 보고 건너뛰면 유저는 새 토큰을 만들어도 스크립트가 받아주지 않는 무한 루프에 갇힌다. 탈출구가 `GITHUB_PAT` 환경변수뿐인 상태로 남기지 않는다.

## 권장 — 배포는 가능하되 확인해 두면 좋다

### T6 · Claude Desktop 세션에서의 실행 환경

Claude Desktop을 열고 세션 안에서 `which gh`(Windows는 `Get-Command gh`)와 `git clone https://github.com/cliwant/contrl-harness.git` 을 실행한다.

기대: 둘 다 성공한다.

터미널에서만 확인하면 이 항목을 놓친다. 설치를 검증하는 환경과 제품이 실제로 도는 환경이 다르기 때문이다. harness는 런타임에 `gh` 를 호출하므로(유저 식별, 위키 repo 탐색, PR 생성) Desktop이 띄우는 프로세스에서 `gh` 가 보이지 않으면 설치는 초록불로 끝나고 파이프라인 중간에 원인 불명으로 실패한다.

훅(usage·핸드오프·렌더 승인)은 Bash 도구가 아니라 Claude Code 프로세스의 환경에서 돈다. Bash 에서 `node --version` 이 되는 것만으로는 부족하고, `/contrl:setup` 의 사용 기록 확인 단계(실제 훅을 발화시켜 `~/.contrl/usage.jsonl` 에 줄이 생기는지 본다)까지 통과해야 한다. macOS 의 Desktop 은 앱을 시작할 때 한 번 셸 프로필(대화형 로그인 셸)을 읽어 그 PATH 를 Claude Code·훅에 넘긴다(`~/Library/Logs/Claude/main.log` 의 `[CCD] Resolved N login-shell env vars`). 그래서 프로필에 없는 경로는 보이지 않고, 프로필을 고친 뒤에는 Desktop 을 재시작해야 한다.

### T7 · Homebrew 없는 macOS 경로

macOS에 새 사용자 계정을 만들어 로그인한 뒤 실행하거나, 기존 계정에서 `--no-brew` 로 실행한다.

기대: gh가 `$HOME/.local/bin` 에 설치되고, 그 경로가 PATH에 없으면 안내가 뜬다. 안내만 띄우고 끝나면 고객은 그 줄을 읽지 않는다는 점을 감안해 결과를 판단한다.

### T8 · 전 과정 성공 경로 (happy path)

깨끗한 상태 + 초대된 계정 + `repo` 스코프 토큰으로 처음부터 끝까지 실행한다.

기대: git 설치 → gh 설치 → python3 · node 준비(macOS 는 T8-m, Windows 는 T8-w 참고, Linux 는 건너뜀) → Claude Code 설치 → PAT 저장 → 플러그인 설치까지 전부 통과하고, Claude Desktop의 Claude Code 화면이 자동으로 열리고 입력창에 `/contrl:setup 한국어로 설치 진행` 이 채워져 있다(전송되지는 않는다). 앱이 없으면 직접 열어 입력하라는 안내로 대체되며, 어느 쪽이든 그 앞줄의 "모든 단계 완료" 는 반드시 출력된다.

```
모든 단계 완료. CONTRL 플러그인이 준비돼 있습니다.
[INFO]  Claude Desktop을 열었습니다. 입력창에 채워진 '/contrl:setup 한국어로 설치 진행' 을 Enter로 실행하세요.
```

끝난 뒤 `claude plugin list` 에 `contrl@contrl-harness` 가 enabled로 보이는지, Claude Desktop 새 세션에서 CONTRL 스킬이 로드되는지 확인한다.

### T8-m · macOS 런타임 준비 (python3 확인 · node 설치) — 아직 미검증

node 단계는 실패해도 설치를 멈추지 않는다(경고 후 계속, 마지막에 "아래 항목은 준비되지 않았습니다" 로 다시 알림). node 없이도 플러그인 설치는 성공해 왔으므로 이 단계가 그 성공을 깨면 안 된다는 것이 가장 중요한 확인점이다. 각 경우 끝에 Desktop 을 재시작하고 `/contrl:setup` 의 사용 기록 확인 단계가 통과하는지 본다(T6).

- **T8-m-a · brew 경로.** brew 가 있고 node 가 없는 Mac. 기대: `brew install node` 로 설치. `brew shellenv` 가 이미 `~/.zprofile` 에 있으면 프로필은 바뀌지 않는다. 없으면 `$(brew --prefix)/bin` 한 줄이 등록된다.
- **T8-m-b · brew 없는 경로.** Apple Silicon 과 Intel 각각 `CONTRL_NO_BREW=1` 로 실행. 기대: nodejs.org 공식 tarball(macOS 13.5+ 는 Node 24, 11+ 는 Node 22)이 SHA-256 검증 후 `~/.local/share/nodejs/<버전>` 에 풀리고 `~/.local/bin/node` 링크만 생긴다(npm·npx 링크 없음). `~/.zprofile` 에 `# added by contrl-setup` 줄이 하나 생긴다.
- **T8-m-c · 이미 node 18+ 가 있음 (회귀 확인).** 기대: `[ OK ] node 이미 설치됨` 만 출력되고 아무것도 바뀌지 않는다 — 프로필 파일 수정 시각 불변, node 설치 없음, 마지막 Desktop 재시작 질문 없음.
- **T8-m-d · node 16 이 있음.** 기대: 기존 node 는 지우지 않고 새 node 를 설치해 PATH 앞에 둔다. nvm 이 `~/.zshrc` 에서 16 을 다시 앞에 넣는 경우에는 "셸 설정에서 node 18 이상이 잡히지 않습니다" 경고와 잡힌 경로가 출력된다(유저의 nvm 설정은 바꾸지 않는다).
- **T8-m-e · 두 번 실행 (회귀 확인).** T8-m-b 직후 같은 명령어를 다시 실행. 기대: node 재설치 없음, 프로필의 등록 줄이 여전히 하나.
- **T8-m-f · 기본 셸이 bash 이고 `~/.profile` 만 있는 계정.** 기대: `~/.bash_profile` 을 새로 만들지 않고 `~/.profile` 에 등록한다(새로 만들면 bash 가 `~/.profile` 을 더 이상 읽지 않는다).
- **T8-m-g · 셸 설정이 멈추는 계정.** `~/.zshrc` 끝에 `read x` 를 넣고 실행. 기대: 셸 확인이 10초 뒤 포기되고 경고만 남는다. 스크립트가 멈추지 않고, 뒤이은 GitHub 토큰 입력 프롬프트가 정상 동작한다.
- **T8-m-h · nodejs.org 가 막힌 네트워크.** 기대: node 단계는 경고로 끝나고 플러그인 설치까지 성공한다.

python3 는 확인만 한다(CLT 의 3.9 로 충분). `install_git` 이 CLT 를 보장하므로 보통 통과한다.

### T8-w · Windows 런타임 설치 (python3 이름 · node) — 아직 미검증

**이 항목은 아직 실제 Windows 에서 실행해 보지 못했다.** `install.ps1` 의 `Install-Python` · `Install-Node` 는 PowerShell 파서 검사와 macOS pwsh 에서의 함수 단위 검사(버전 판정, 후보 탐색·정렬)만 통과한 상태다.

Python 단계의 목표는 설치를 최대한 피하는 것이다. 세 갈래를 각각 확인한다.

**T8-w-a · 기존 Python 재사용.** python.org 의 3.11 을 미리 설치해 `python`·`py` 는 되고 `python3` 는 Store 를 여는 상태에서 실행한다.

기대: winget 설치 없이 "이미 설치된 Python 에 python3 이름을 연결했습니다 (Python 3.11.x)" 가 출력된다. 3.11 설치 폴더에 `python3.exe` 사본이 생기고 그 폴더가 사용자 PATH 맨 앞에 들어간다. 새 PowerShell 에서 `python3 --version` 이 3.11 을 출력해야 한다. 3.9 와 3.12 가 함께 있으면 3.12 쪽에 연결돼야 한다(폴더 이름 순이 아니라 버전 순).

**T8-w-b · Python 없음.** python 이 전혀 없는 Windows 에서 실행한다.

기대: winget 으로 Python 3.12 가 설치되고 T8-w-a 와 같이 `python3` 이름이 연결된다. Store 의 앱 실행 별칭이 여전히 앞서면 별칭을 끄라는 경고를 남기고 설치를 계속한다(Claude Code·플러그인 설치와 Desktop 열기까지 진행되고, 마지막 "아래 항목은 준비되지 않았습니다" 목록에 다시 나온다) — 그 경우 안내대로 끈 뒤 재실행해 통과하는지 본다.

**T8-w-c · 쓰기 권한 없는 폴더의 Python.** 모든 사용자용으로 `C:\Program Files\Python3xx` 에만 Python 이 있는 상태에서 일반 권한으로 실행한다.

기대: 그 폴더에 사본을 만들지 못하므로 재사용을 건너뛰고 winget(사용자 범위) 설치로 넘어간다. 중단되지 않아야 한다.

Node.js LTS 는 UAC 승인 창이 한 번 뜬 뒤 설치되고 `node --version` 이 18 이상이어야 한다. UAC 창을 거부하면 경고만 남기고 설치를 계속해 Desktop 열기까지 진행돼야 한다(마지막 목록에 node 가 다시 나온다). 끝으로 Claude Desktop 세션 안에서 `python3 --version` 과 `node --version` 이 둘 다 잡히는지 확인한다(T6 과 같은 이유 — 훅은 Desktop 이 띄운 프로세스에서 돈다).

### T9 · Claude Desktop 자동 열기 (Windows — 아직 미검증)

**이 항목은 아직 한 번도 실제로 실행해 보지 못했다.** 마무리 단계의 `claude://code/new?q=…` 딥링크는 macOS(Desktop 1.46388.1)에서만 동작을 확인했고, `install.ps1` 의 `Open-ClaudeDesktop` 은 PowerShell 문법 검사만 통과한 상태다.

Claude Desktop이 설치된 Windows에서 T8을 끝까지 돌리고 확인한다.

기대: Claude Desktop이 앞으로 오고 Claude Code 새 세션 입력창에 `/contrl:setup 한국어로 설치 진행` 이 채워져 있다(전송은 되지 않는다). 아래 세 경우 모두 "모든 단계 완료" 가 먼저 출력되고 터미널이 닫히지 않아야 한다.

- Desktop 설치됨 → `[INFO]  Claude Desktop을 열었습니다. …`
- Desktop 미설치(프로토콜 미등록) → `[INFO]  Claude Desktop을 직접 연 뒤, …`
- EDR/AppLocker가 Start-Process 를 막는 관리형 PC → 위 미설치와 같은 안내

확인되지 않은 것: 프로토콜이 없을 때 Windows가 예외 대신 "앱 선택" 대화상자를 띄우는지, Desktop이 꺼진 상태(cold start)에서도 프리필이 유지되는지.

### T10 · Desktop 재시작 제안 (두 OS) — 아직 미검증

이번 실행에서 node 를 설치했거나 PATH 를 바꿨고(Windows 는 python3 이름 연결 포함) Desktop 이 떠 있을 때만 `[Y/n]` 으로 재시작을 묻는다. 기본값은 Y 다(Enter 만 눌러도 재시작).

- **Desktop 실행 중 + Enter(기본값) 또는 y.** 기대: Desktop 이 완전히 꺼진 것을 확인한 뒤 딥링크로 다시 열리고 프리필이 채워져 있다. 다시 열린 Desktop 에서 setup 의 사용 기록 확인 단계가 통과해야 재시작이 효과가 있었던 것이다.
- **Desktop 실행 중 + n.** 기대: Desktop 은 그대로이고, 완전 종료 후 다시 열라는 안내와 `/contrl:setup` 입력 안내가 나온다. 딥링크는 열지 않는다.
- **Desktop 꺼져 있음.** 기대: 질문 없이 기존처럼 딥링크로 연다.
- **node 가 원래 있던 경우.** 기대: 질문 없음(T8-m-c).
- **터미널에서 Claude Code CLI(`claude`)가 돌고 있음.** y 로 재시작해도 CLI 세션은 꺼지지 않아야 한다. macOS 는 프로세스 이름 `Claude`(대문자)만 잡는다. Windows 는 `%LOCALAPPDATA%\AnthropicClaude\` 또는 `WindowsApps\Claude_` 경로의 claude.exe 만 잡는다 — 실제 Desktop 설치 경로가 이 패턴에 맞는지 실기기에서 확인한다. 맞지 않으면 질문 없이 딥링크만 열린다(기존 동작).
- **Desktop 의 Claude Code 세션 안에서 스크립트 실행.** 기대: 묻지 않고 안내만 출력한다(재시작하면 스크립트 자신이 꺼진다).
- **미리 눌러 둔 Enter.** 토큰을 붙여넣은 뒤 Enter 를 여러 번 눌러 두고 기다린다. 기대: 질문이 뜬 뒤 다시 입력을 기다린다 — 미리 눌러 둔 Enter 가 재시작 동의로 처리되면 안 된다(기본값이 Y 라 가장 위험한 경우).
- **macOS: 다른 계정의 Desktop 만 떠 있음(빠른 사용자 전환).** 기대: 질문 없이 기존처럼 딥링크로 내 Desktop 을 연다.
- **Windows: 관리자 권한 PowerShell.** 기대: 재시작하지 않고 안내만 출력한다(다시 띄운 Desktop 이 관리자 권한으로 뜨지 않게).
- **Windows: WMI(CIM) 조회가 막힌 PC.** 기대: 재시작하지 않고 안내만 출력한다.
- **Windows: 재시작 후 남은 claude.exe.** Windows 는 부모를 강제 종료해도 자식이 함께 꺼지지 않을 수 있다. 재시작 직후 작업 관리자에서 Desktop 이 띄웠던 claude.exe(`%APPDATA%\Claude\…` 등)가 고아로 남아 있지 않은지 확인한다.
- **Windows: 재시작 후 Desktop 세션에서 `node --version`.** 스크립트가 `Start-Process` 로 띄운 Desktop 이 갱신된 PATH 를 물려받는지 확인한다. MSIX 설치에서는 다를 수 있다.

## 검증하지 않는 것

**환경변수 스위치(`CONTRL_SKIP_VERIFY`).** 개발용이며 고객 경로에서 쓰이지 않는다. 동작하지 않아도 고객 영향이 없다.

**winget 없는 구형 Windows.** winget 부재는 명확한 메시지로 즉시 종료되므로 별도 재현이 불필요하다.
