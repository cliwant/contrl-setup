<#
    install.ps1 — CONTRL 설치 (Windows)

      1. git 설치 (winget)
      2. GitHub CLI(gh) 설치 (winget)
      3. Claude Code 설치
      4. GitHub PAT 저장 + git credential helper 연결
      5. CONTRL 플러그인 설치 — 실패하면 원인을 안내하고 최대 3회까지 토큰 재입력
         (플러그인 설치가 저장소 접근 확인을 겸한다 — 별도의 clone 검증은 하지 않는다)

    사용법:
      irm https://raw.githubusercontent.com/cliwant/contrl-setup/main/install.ps1 | iex

    이 경로에서는 스크립트를 파일로 저장하지 않고 HTTP 응답을 그대로 실행하므로,
    인코딩은 응답 헤더의 charset을 따른다(파일 BOM 규칙이 적용되지 않는다).
    파일로 내려받아 직접 실행하는 경우 PowerShell 5.1은 BOM이 없으면 CP949로 읽어
    한글이 깨지므로, 그때는 UTF-8 with BOM으로 저장해야 한다.

    파라미터 대신 환경변수를 쓴다 — `irm | iex` 형태로는 파라미터를 넘길 수 없다.
      $env:GITHUB_PAT           비대화형 실행 (첫 시도에만 사용)
      $env:CONTRL_SKIP_VERIFY   플러그인 설치(저장소 접근 확인) 생략
#>

# 주의: 네이티브 명령(gh/git/winget)은 stderr 출력이 ErrorRecord로 변환되므로
# 'Stop'을 전역으로 두면 정상적인 진단 메시지에도 스크립트가 죽는다.
# 모든 외부 명령은 아래 Invoke-Native 로 감싸고 종료 코드로만 판정한다.
$ErrorActionPreference = 'Stop'

$Repo        = 'cliwant/contrl-harness'
$Marketplace = 'contrl-harness'   # marketplace.json 의 name
$Plugin      = 'contrl'           # plugin.json 의 name
$MaxAttempts = 3
# scopes 파라미터로 repo·admin:org 체크박스를 미리 채워 둔다 — 스코프 누락이 접근 실패의 절반이다.
$TokenUrl    = 'https://github.com/settings/tokens/new?scopes=repo,admin:org&description=CONTRL%20harness&default_expires_at=none'
$SkipVerify  = -not [string]::IsNullOrWhiteSpace($env:CONTRL_SKIP_VERIFY)

# ── 로깅 ──────────────────────────────────────────────────────────────
function Write-Info { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "[ OK ]  $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }

# `irm | iex` 실행에서는 스크립트가 사용자 세션의 스코프에서 그대로 돌기 때문에,
# 여기서 exit를 부르면 스크립트가 아니라 터미널 창이 통째로 닫힌다 — 유저는
# 실패 메시지를 읽을 새도 없다. 그래서 exit 대신 throw로 중단하고, 맨 아래
# 실행 구간의 try/catch가 받아서 세션을 살려 둔 채 끝낸다.
function Stop-Fail  { param([string]$Msg) Write-Host "[FAIL]  $Msg" -ForegroundColor Red; throw 'CONTRL-INSTALL-FAILED' }

# ── 네이티브 명령 실행 래퍼 ───────────────────────────────────────────
# stderr를 ErrorRecord로 승격시키지 않고, 종료 코드와 출력을 함께 돌려준다.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [switch]$Passthru   # 지정 시 출력을 콘솔에 그대로 흘려보냄
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        $lines = & $Script 2>&1 | ForEach-Object { "$_" }
        $code  = $LASTEXITCODE
        if ($Passthru -and $lines) { $lines | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray } }
        [pscustomobject]@{
            ExitCode = $code
            Output   = if ($lines) { ($lines -join "`n").Trim() } else { '' }
        }
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function Test-Command {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# winget이 방금 설치한 프로그램은 현재 세션 PATH에 없다. 레지스트리에서 다시 읽어온다.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# ── 사전 점검 ─────────────────────────────────────────────────────────
# Stop-Fail이 throw 기반이므로 top-level이 아니라 함수로 두고, 맨 아래
# 실행 구간의 try 안에서 부른다.
function Test-Prerequisites {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Stop-Fail "PowerShell 5.1 이상이 필요합니다. (현재: $($PSVersionTable.PSVersion))"
    }

    Update-SessionPath

    if (-not (Test-Command 'winget')) {
        Stop-Fail "winget(App Installer)이 없습니다. Microsoft Store에서 'App Installer'를 먼저 설치해 주세요."
    }

    Write-Info "플랫폼: Windows / 패키지 매니저: winget"
}

# ── 공통 설치 함수 ────────────────────────────────────────────────────
function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$DisplayName
    )
    Write-Info "$DisplayName 설치 중... (winget: $Id)"

    # winget은 '이미 최신 버전'일 때도 0이 아닌 코드를 반환하므로
    # 종료 코드가 아니라 설치 후 명령 존재 여부로 판정한다.
    Invoke-Native -Passthru {
        winget install --id $Id --exact --source winget --silent `
            --accept-package-agreements --accept-source-agreements
    } | Out-Null

    Update-SessionPath
}

# ── 1. git 설치 ───────────────────────────────────────────────────────
function Install-Git {
    Update-SessionPath
    if (Test-Command 'git') {
        $v = (Invoke-Native { git --version }).Output
        Write-Ok "git 이미 설치됨 ($v)"
        return
    }
    Install-WingetPackage -Id 'Git.Git' -DisplayName 'Git'
    if (-not (Test-Command 'git')) {
        Stop-Fail "git 설치 실패 — 새 PowerShell 창을 열고 다시 실행해 보세요."
    }
    $v = (Invoke-Native { git --version }).Output
    Write-Ok "git 설치 완료 ($v)"
}

# ── 2. gh CLI 설치 ────────────────────────────────────────────────────
function Get-GhVersion {
    $out = (Invoke-Native { gh --version }).Output
    ($out -split "`n" | Select-Object -First 1).Trim()
}

function Install-Gh {
    Update-SessionPath
    if (Test-Command 'gh') {
        Write-Ok "gh 이미 설치됨 ($(Get-GhVersion))"
        return
    }
    Install-WingetPackage -Id 'GitHub.cli' -DisplayName 'GitHub CLI'
    if (-not (Test-Command 'gh')) {
        Write-Warn "gh 설치에 실패했습니다. gh 없이 계속 진행합니다 (토큰 저장 단계는 건너뜁니다)."
        return
    }
    Write-Ok "gh 설치 완료 ($(Get-GhVersion))"
}

# ── 3. Claude Code 설치 ───────────────────────────────────────────────
# 공식 installer가 claude.exe를 %USERPROFILE%\.local\bin 에 설치하고도 사용자
# PATH 레지스트리 등록에는 실패한 채 exit 0으로 끝나는 사례가 있다(경고로만
# 처리). 산출물이 실제로 있으면 PATH를 직접 등록한다. 등록 성공 여부와 무관하게
# claude.exe 존재 여부를 반환한다.
function Register-ClaudeBinPath {
    $claudeBin = Join-Path $env:USERPROFILE '.local\bin'
    if (-not (Test-Path (Join-Path $claudeBin 'claude.exe'))) { return $false }

    $key = 'HKCU:\Environment'
    $raw = (Get-Item $key).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    if ($raw -notmatch [regex]::Escape('.local\bin')) {
        # [Environment]::SetEnvironmentVariable 은 값을 REG_SZ로 써서 기존
        # %USERPROFILE% 류 항목의 확장이 깨진다 — REG_EXPAND_SZ 타입을 보존해
        # 직접 쓴다. 빈 항목(중복 세미콜론)은 이때 정리된다.
        $entries = @($raw -split ';' | Where-Object { $_ }) + '%USERPROFILE%\.local\bin'
        Set-ItemProperty -Path $key -Name Path -Value ($entries -join ';') -Type ExpandString

        # 이후에 뜨는 프로세스(예: Claude Desktop)가 재로그인 없이 갱신된 PATH를
        # 보도록 환경 변경을 브로드캐스트한다. 실패해도 치명적이지 않다.
        try {
            Add-Type -Namespace Win32 -Name Env -MemberDefinition '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
            [UIntPtr]$result = [UIntPtr]::Zero
            [Win32.Env]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
        }
        catch { }
    }

    Update-SessionPath
    # Update-SessionPath 는 레지스트리의 %VAR% 미확장 값을 그대로 이어붙일 수
    # 있으므로, 현재 세션 PATH에는 확장된 실제 경로를 별도로 추가한다.
    $env:Path += ";$claudeBin"
    return $true
}

function Install-Claude {
    Update-SessionPath
    # PATH 미등록 상태로 이전 실행이 중단됐다면 여기서 복구된다 — 이미 받아 둔
    # 바이너리를 살려서 재다운로드 루프를 끊는다.
    if (-not (Test-Command 'claude')) { Register-ClaudeBinPath | Out-Null }
    if (Test-Command 'claude') {
        $v = (Invoke-Native { claude --version }).Output
        Write-Ok "Claude Code 이미 설치됨 ($v)"
        return
    }

    Write-Info "Claude Code 설치 중..."
    # 공식 설치 스크립트 — 자동 업데이트되는 네이티브 빌드를 설치한다.
    # 공식 스크립트는 내부에서 exit를 호출하므로 iex로 현재 세션에서 돌리면
    # 사용자 터미널이 통째로 닫힌다. 자식 프로세스로 격리해 실행하고
    # 종료 코드로만 판정한다.
    #
    # Start-Process 는 쓰지 않는다 — 관리형 PC의 보안 정책(EDR/AppLocker)이
    # ShellExecute 경로의 powershell 재기동을 '액세스 거부'로 차단하는 사례가
    # 있었다. 임시 파일로 받아 & 호출 연산자로 직접 실행하면 콘솔을 상속하는
    # 일반 자식 프로세스라 정책에 덜 걸린다.
    $installerPath = Join-Path $env:TEMP 'claude-code-install.ps1'
    try {
        Invoke-RestMethod 'https://claude.ai/install.ps1' -OutFile $installerPath
    }
    catch {
        Stop-Fail "Claude Code 설치 스크립트 다운로드 실패`n        $($_.Exception.Message)"
    }

    # PS 5.1 은 $PSHOME\powershell.exe, PowerShell 7+ 은 $PSHOME\pwsh.exe
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' }
             else { Join-Path $PSHOME 'powershell.exe' }
    $run = Invoke-Native -Passthru {
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $installerPath
    }
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
    if ($run.ExitCode -ne 0) {
        # 설치 로그는 -Passthru 로 이미 화면에 출력돼 있다.
        Stop-Fail "Claude Code 설치 실패 (exit code $($run.ExitCode))"
    }

    Update-SessionPath
    if (-not (Test-Command 'claude')) { Register-ClaudeBinPath | Out-Null }
    if (-not (Test-Command 'claude')) {
        Stop-Fail "Claude Code 설치 후에도 claude 명령을 찾지 못했습니다. 새 PowerShell 창을 열고 다시 실행해 보세요."
    }
    $v = (Invoke-Native { claude --version }).Output
    Write-Ok "Claude Code 설치 완료 ($v)"
}

# ── 4. 토큰 입력 ──────────────────────────────────────────────────────
function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# 브라우저를 직접 연다 — 터미널에서 긴 주소를 복사해 옮기는 단계가 빠진다.
# 기본 브라우저가 없거나 열기에 실패하면 주소를 그대로 보여준다.
function Open-Url {
    param([string]$Url)
    try { Start-Process $Url -ErrorAction Stop; $true } catch { $false }
}

function Show-TokenPage {
    if (Open-Url $TokenUrl) {
        Write-Info "브라우저에 토큰 발급 페이지를 열었습니다. 토큰을 만든 뒤 값을 복사하세요. (화면의 초록색 버튼)"
        Write-Host "        열리지 않으면 직접 접속: $TokenUrl" -ForegroundColor DarkGray
    } else {
        Write-Info "아래 주소에서 토큰을 만든 뒤 값을 복사하세요. (화면의 초록색 버튼)"
        Write-Host "        $TokenUrl" -ForegroundColor DarkGray
    }
}

function Read-Token {
    $secure = Read-Host -Prompt 'GitHub 토큰을 붙여넣고 Enter (입력은 화면에 표시되지 않습니다)' -AsSecureString
    ConvertFrom-SecureStringPlain -Secure $secure
}

# 실패해도 멈추지 않는다 — 저장소가 공개이거나 다른 credential helper가
# 이미 있으면 플러그인 설치는 그대로 성공한다. 판정은 Install-Plugin이 한다.
function Set-GitCredentialHelper {
    if (-not (Test-Command 'gh')) { return }
    $setup = Invoke-Native { gh auth setup-git --hostname github.com }
    if ($setup.ExitCode -ne 0) {
        Write-Warn "git 자격증명 연결에 실패했습니다. 그대로 플러그인 설치를 시도합니다."
    }
}

# ── 5. 플러그인 설치 (저장소 접근 확인 겸용) ──────────────────────────
# GitHub는 권한 없는 private 저장소를 404로 숨기므로 스코프 누락과 초대 미수락을
# 구분할 수 없다. 그래서 둘 다 안내한다 — 한쪽만 지목하면 나머지 절반의
# 사용자를 엉뚱한 곳으로 보내게 된다.
function Show-AccessFailureCauses {
    Write-Warn "저장소에 접근하지 못했습니다. 원인은 보통 둘 중 하나입니다:"
    Write-Host "        1) 토큰을 만들 때 'repo' 항목을 체크하지 않음" -ForegroundColor Yellow
    Write-Host "        2) 초대 메일을 아직 수락하지 않음 (수락한 뒤 다시 시도)" -ForegroundColor Yellow
}

# marketplace add/update 가 private 저장소를 clone하므로 별도의 검증 clone이
# 필요 없다 — 여기가 실패하면 곧 저장소 접근 실패다.
function Install-Plugin {
    # owner/repo 축약형은 기본이 SSH clone 이다. 이 스크립트는 PAT(HTTPS)만
    # 구성하므로 HTTPS를 강제하고, 자격증명이 통하지 않을 때 git이 사용자명을
    # 되묻고 멈추는 것도 막는다.
    $env:CLAUDE_CODE_PLUGIN_PREFER_HTTPS = '1'
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
        Write-Info "CONTRL 플러그인 설치 중..."

        $list = Invoke-Native { claude plugin marketplace list }
        if ($list.ExitCode -eq 0 -and $list.Output -match [regex]::Escape($Marketplace)) {
            # 재시도(새 토큰) 경로 — 이미 등록된 marketplace를 새 자격증명으로 갱신
            if ((Invoke-Native { claude plugin marketplace update $Marketplace }).ExitCode -ne 0) { return $false }
        }
        else {
            if ((Invoke-Native { claude plugin marketplace add $Repo }).ExitCode -ne 0) { return $false }
        }

        if ((Invoke-Native { claude plugin install "$Plugin@$Marketplace" --scope user }).ExitCode -ne 0) { return $false }

        $installed = Invoke-Native { claude plugin list }
        if ($installed.Output -notmatch [regex]::Escape("$Plugin@$Marketplace")) { return $false }

        Write-Ok "CONTRL 플러그인 설치 완료 ($Plugin@$Marketplace)"
        return $true
    }
    finally {
        Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    }
}

# 저장된 인증으로 먼저 시도하고, 실패하면 토큰을 다시 받아 최대 $MaxAttempts회 재시도한다.
# 저장된 토큰이 '유효하지만 이 저장소에는 권한이 없는' 상태여도 gh auth status는 성공하므로,
# 인증 여부만 보고 건너뛰면 새 토큰을 만들어도 반영되지 않는 상태에 갇힌다.
# gh 로그인·credential helper 연결은 실패해도 멈추지 않는다 — 저장소가 공개이거나
# 자격증명이 다른 경로로 이미 있으면 설치는 그대로 통과하기 때문이다.
# 성공/실패 판정은 오직 Install-Plugin 결과로만 한다.
function Confirm-RepoAccess {
    $envToken = [Environment]::GetEnvironmentVariable('GITHUB_PAT')
    $hasGh = Test-Command 'gh'

    if ($SkipVerify) {
        Write-Warn "CONTRL_SKIP_VERIFY: 플러그인 설치 생략"
        return
    }

    if ([string]::IsNullOrWhiteSpace($envToken) -and $hasGh -and (Invoke-Native { gh auth status }).ExitCode -eq 0) {
        $who = (Invoke-Native { gh api user --jq .login }).Output
        Write-Ok "GitHub 인증 이미 구성됨 (사용자: $who)"
        Set-GitCredentialHelper
        if (Install-Plugin) { return }
        Show-AccessFailureCauses
        Write-Info "새 토큰으로 다시 시도합니다."
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -eq 1 -and -not [string]::IsNullOrWhiteSpace($envToken)) {
            $token = $envToken
        }
        else {
            Show-TokenPage
            $token = Read-Token
        }

        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-Warn "빈 토큰입니다. ($attempt/$MaxAttempts)"
            continue
        }

        if ($hasGh) {
            Write-Info "토큰 저장 중..."
            # 파이프로 전달 — 명령행 인자로 넘기지 않으므로 히스토리/프로세스 목록에 남지 않는다.
            $login = Invoke-Native {
                $token | gh auth login --hostname github.com --git-protocol https --with-token
            }
            if ($login.ExitCode -eq 0) {
                $who = (Invoke-Native { gh api user --jq .login }).Output
                Write-Ok "토큰 저장 완료 (사용자: $who)"
                Set-GitCredentialHelper
            }
            else {
                Write-Warn "gh 토큰 저장에 실패했습니다. 그대로 플러그인 설치를 시도합니다. ($attempt/$MaxAttempts)"
            }
        }
        else {
            Write-Warn "gh가 없어 토큰을 저장하지 못합니다. 그대로 플러그인 설치를 시도합니다."
        }
        Remove-Variable token -ErrorAction SilentlyContinue

        if (Install-Plugin) { return }

        Show-AccessFailureCauses
        if ($attempt -lt $MaxAttempts) {
            Write-Info "다시 시도합니다. ($attempt/$MaxAttempts)"
        }
    }

    Stop-Fail "$MaxAttempts회 모두 실패했습니다. 위 두 가지를 확인한 뒤 같은 명령어를 다시 실행하거나,`n        화면에 나온 메시지를 그대로 담당자에게 전달해 주세요."
}

# ── 5. 마무리 ─────────────────────────────────────────────────────────
# 설치가 끝나면 Claude Desktop의 Claude Code 화면을 바로 띄우고, 입력창에
# "/contrl:setup 한국어로 설치 진행" 을 채워 둔다(전송은 하지 않는다 — Enter는 사용자 몫).
# claude:// 딥링크는 Desktop 앱이 등록하므로, 앱이 없거나 실행이 막히면
# (EDR/AppLocker, 프로토콜 미등록) 열리지 않는다.
#
# 이 단계는 편의 기능이다. 어떤 이유로 실패해도 설치 결과에는 영향이 없어야
# 하므로, 함수는 예외를 밖으로 던지지 않고 $true/$false 만 돌려준다.
# 호출 측은 성공 메시지를 먼저 출력한 뒤 이 함수를 부르고, 실패하면 직접
# 열라는 안내로 대신한다. 이미 실행 중이면 새로 띄우지 않고 앞으로 가져온다.
# q= 값은 URL 인코딩된 "/contrl:setup 한국어로 설치 진행" (한글은 UTF-8 퍼센트 인코딩).
#
# ※ 검증 상태: Windows에서는 아직 실제로 테스트하지 못했다. 딥링크 동작은
#    macOS(Desktop 1.46388.1)에서만 확인했고, Windows는 문법 검사만 통과한
#    상태다. TESTING.md T9 시나리오로 확인이 필요하다.
$SetupDeepLink = 'claude://code/new?q=%2Fcontrl%3Asetup%20%ED%95%9C%EA%B5%AD%EC%96%B4%EB%A1%9C%20%EC%84%A4%EC%B9%98%20%EC%A7%84%ED%96%89&source=url_external'

function Open-ClaudeDesktop {
    $opened = $false
    try {
        # 전역 $ErrorActionPreference = 'Stop' 이라 오류는 모두 예외로 오고,
        # 아래 catch 가 전부 받는다. 프로토콜 미등록·정책 차단·기타 예외 모두
        # $false 로 귀결된다.
        Start-Process $SetupDeepLink -ErrorAction Stop
        $opened = $true
    }
    catch {
        $opened = $false
    }
    return $opened
}

# ── 실행 ──────────────────────────────────────────────────────────────
# Stop-Fail의 throw를 여기서 받는다. exit를 쓰지 않으므로 `irm | iex` 로 실행한
# 사용자 터미널이 닫히지 않고, 실패 메시지가 화면에 남는다.
try {
    Test-Prerequisites
    Install-Git
    Install-Gh
    Install-Claude
    Confirm-RepoAccess

    Write-Host ''
    Write-Ok "모든 단계 완료. CONTRL 플러그인이 준비돼 있습니다."

    # 아래는 실패해도 무방한 편의 단계 — 어떤 결과든 안내 문구만 달라진다.
    if (Open-ClaudeDesktop) {
        Write-Info "Claude Desktop을 열었습니다. 입력창에 채워진 '/contrl:setup 한국어로 설치 진행' 을 Enter로 실행하세요."
    } else {
        Write-Info "Claude Desktop을 직접 연 뒤, Claude Code 입력창에 '/contrl:setup 한국어로 설치 진행' 을 입력해 실행하세요."
    }
}
catch {
    if ($_.FullyQualifiedErrorId -notmatch 'CONTRL-INSTALL-FAILED') {
        # Stop-Fail을 거치지 않은 예상 밖의 오류 — 원인을 그대로 보여준다.
        Write-Host "[FAIL]  예상하지 못한 오류로 설치를 중단했습니다:" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host "        문제가 해결되면 같은 명령어로 다시 실행해 주세요." -ForegroundColor Yellow
}
