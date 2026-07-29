<#
    install.ps1 — CONTRL 설치 (Windows)

      1. git 설치 (winget)
      2. GitHub CLI(gh) 설치 (winget)
      3. GitHub PAT 저장 + git credential helper 연결
      4. 저장소 접근 확인 — 실패하면 원인을 안내하고 최대 3회까지 토큰 재입력

    사용법:
      irm https://raw.githubusercontent.com/cliwant/contrl-setup/main/install.ps1 | iex

    이 경로에서는 스크립트를 파일로 저장하지 않고 HTTP 응답을 그대로 실행하므로,
    인코딩은 응답 헤더의 charset을 따른다(파일 BOM 규칙이 적용되지 않는다).
    파일로 내려받아 직접 실행하는 경우 PowerShell 5.1은 BOM이 없으면 CP949로 읽어
    한글이 깨지므로, 그때는 UTF-8 with BOM으로 저장해야 한다.

    파라미터 대신 환경변수를 쓴다 — `irm | iex` 형태로는 파라미터를 넘길 수 없다.
      $env:GITHUB_PAT           비대화형 실행 (첫 시도에만 사용)
      $env:CONTRL_SKIP_VERIFY   저장소 접근 확인 생략
#>

# 주의: 네이티브 명령(gh/git/winget)은 stderr 출력이 ErrorRecord로 변환되므로
# 'Stop'을 전역으로 두면 정상적인 진단 메시지에도 스크립트가 죽는다.
# 모든 외부 명령은 아래 Invoke-Native 로 감싸고 종료 코드로만 판정한다.
$ErrorActionPreference = 'Stop'

$Repo        = 'cliwant/contrl-harness'
$MaxAttempts = 3
# scopes 파라미터로 repo 체크박스를 미리 채워 둔다 — 스코프 누락이 접근 실패의 절반이다.
$TokenUrl    = 'https://github.com/settings/tokens/new?scopes=repo&description=CONTRL%20harness'
$SkipVerify  = -not [string]::IsNullOrWhiteSpace($env:CONTRL_SKIP_VERIFY)

# ── 로깅 ──────────────────────────────────────────────────────────────
function Write-Info { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "[ OK ]  $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Stop-Fail  { param([string]$Msg) Write-Host "[FAIL]  $Msg" -ForegroundColor Red; exit 1 }

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
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Stop-Fail "PowerShell 5.1 이상이 필요합니다. (현재: $($PSVersionTable.PSVersion))"
}

Update-SessionPath

if (-not (Test-Command 'winget')) {
    Stop-Fail "winget(App Installer)이 없습니다. Microsoft Store에서 'App Installer'를 먼저 설치해 주세요."
}

Write-Info "플랫폼: Windows / 패키지 매니저: winget"

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
        Stop-Fail "gh 설치 실패 — 새 PowerShell 창을 열고 다시 실행해 보세요."
    }
    Write-Ok "gh 설치 완료 ($(Get-GhVersion))"
}

# ── 3. 토큰 입력 ──────────────────────────────────────────────────────
function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Open-TokenPage {
    Write-Info "토큰 발급 페이지를 엽니다. 화면의 초록색 버튼을 눌러 토큰을 만든 뒤 값을 복사하세요."
    Write-Host "        $TokenUrl" -ForegroundColor DarkGray
    try { Start-Process $TokenUrl | Out-Null }
    catch { Write-Warn "브라우저를 자동으로 열지 못했습니다. 위 주소를 직접 열어 주세요." }
}

function Read-Token {
    $secure = Read-Host -Prompt 'GitHub 토큰을 붙여넣고 Enter (입력은 화면에 표시되지 않습니다)' -AsSecureString
    ConvertFrom-SecureStringPlain -Secure $secure
}

function Set-GitCredentialHelper {
    $setup = Invoke-Native { gh auth setup-git --hostname github.com }
    if ($setup.ExitCode -ne 0) {
        Stop-Fail "git 자격증명 연결에 실패했습니다.`n        $($setup.Output)"
    }
}

# ── 4. 저장소 접근 확인 ───────────────────────────────────────────────
# GitHub는 권한 없는 private 저장소를 404로 숨기므로 스코프 누락과 초대 미수락을
# 구분할 수 없다. 그래서 둘 다 안내한다 — 한쪽만 지목하면 나머지 절반의
# 사용자를 엉뚱한 곳으로 보내게 된다.
function Show-AccessFailureCauses {
    Write-Warn "저장소에 접근하지 못했습니다. 원인은 보통 둘 중 하나입니다:"
    Write-Host "        1) 토큰을 만들 때 'repo' 항목을 체크하지 않음" -ForegroundColor Yellow
    Write-Host "        2) 초대 메일을 아직 수락하지 않음 (수락한 뒤 다시 시도)" -ForegroundColor Yellow
}

function Test-RepoAccess {
    $tmpRoot = Join-Path $env:TEMP ("contrl-verify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $tmpRepo = Join-Path $tmpRoot 'repo'
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    try {
        Write-Info "저장소 접근 확인 중..."
        # 자격증명이 통하지 않을 때 git이 사용자명을 되묻고 멈추는 것을 막는다.
        $env:GIT_TERMINAL_PROMPT = '0'
        $clone = Invoke-Native { git clone --depth 1 --quiet "https://github.com/$Repo.git" $tmpRepo }
        if ($clone.ExitCode -ne 0) { return $false }

        $head = (Invoke-Native { git -C $tmpRepo rev-parse --short HEAD }).Output
        Write-Ok "저장소 접근 확인 (HEAD: $head)"
        return $true
    }
    finally {
        Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
        # 성공/실패/중단 어느 경우든 임시 디렉토리 정리
        if (Test-Path $tmpRoot) {
            # .git 내부 읽기 전용 속성 때문에 삭제가 막히는 경우 대비
            Get-ChildItem -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
            Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# 저장된 인증으로 먼저 시도하고, 실패하면 토큰을 다시 받아 최대 $MaxAttempts회 재시도한다.
# 저장된 토큰이 '유효하지만 이 저장소에는 권한이 없는' 상태여도 gh auth status는 성공하므로,
# 인증 여부만 보고 건너뛰면 새 토큰을 만들어도 반영되지 않는 상태에 갇힌다.
function Confirm-RepoAccess {
    $envToken = [Environment]::GetEnvironmentVariable('GITHUB_PAT')

    if ([string]::IsNullOrWhiteSpace($envToken) -and (Invoke-Native { gh auth status }).ExitCode -eq 0) {
        $who = (Invoke-Native { gh api user --jq .login }).Output
        Write-Ok "GitHub 인증 이미 구성됨 (사용자: $who)"
        Set-GitCredentialHelper
        if ($SkipVerify) {
            Write-Warn "CONTRL_SKIP_VERIFY: 저장소 접근 확인 생략"
            return
        }
        if (Test-RepoAccess) { return }
        Show-AccessFailureCauses
        Write-Info "새 토큰으로 다시 시도합니다."
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -eq 1 -and -not [string]::IsNullOrWhiteSpace($envToken)) {
            $token = $envToken
        }
        else {
            Open-TokenPage
            $token = Read-Token
        }

        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-Warn "빈 토큰입니다. ($attempt/$MaxAttempts)"
            continue
        }

        Write-Info "토큰 저장 중..."
        # 파이프로 전달 — 명령행 인자로 넘기지 않으므로 히스토리/프로세스 목록에 남지 않는다.
        $login = Invoke-Native {
            $token | gh auth login --hostname github.com --git-protocol https --with-token
        }
        Remove-Variable token -ErrorAction SilentlyContinue

        if ($login.ExitCode -ne 0) {
            Write-Warn "토큰이 유효하지 않습니다. 값을 다시 확인해 주세요. ($attempt/$MaxAttempts)"
            continue
        }

        $who = (Invoke-Native { gh api user --jq .login }).Output
        Write-Ok "토큰 저장 완료 (사용자: $who)"
        Set-GitCredentialHelper

        if ($SkipVerify) {
            Write-Warn "CONTRL_SKIP_VERIFY: 저장소 접근 확인 생략"
            return
        }
        if (Test-RepoAccess) { return }

        Show-AccessFailureCauses
        if ($attempt -lt $MaxAttempts) {
            Write-Info "다시 시도합니다. ($attempt/$MaxAttempts)"
        }
    }

    Stop-Fail "$MaxAttempts회 모두 실패했습니다. 위 두 가지를 확인한 뒤 같은 명령어를 다시 실행하거나,`n        화면에 나온 메시지를 그대로 담당자에게 전달해 주세요."
}

# ── 실행 ──────────────────────────────────────────────────────────────
Install-Git
Install-Gh
Confirm-RepoAccess

Write-Host ''
Write-Ok "모든 단계 완료. Claude Desktop을 열어 주세요."
