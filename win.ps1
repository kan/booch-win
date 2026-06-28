<#
.SYNOPSIS
    booch-win bootstrap: 素の Windows から private dotfiles を入れ、dotfiles-win setup を起動する。

.DESCRIPTION
    git すら無い Windows から「dotfiles-win setup が走る状態」までを 1 コマンドで持っていく。
    winget で git / gh を入れ、gh のブラウザ認証で private repo を clone し、本体へ委譲する。

    Windows PowerShell 5.1 で動く構文に限定する（素の環境に pwsh は無い）。
    冪等: 各ステップ「無ければ入れる / 既存なら pull」。

.EXAMPLE
    irm https://raw.githubusercontent.com/kan/booch-win/main/win.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/kan/booch-win/main/win.ps1))) -Dir 'D:\dev\dotfiles'

.NOTES
    STATUS: スケルトン（未検証）。クリーンに近い環境でのスモークは #7 で実施する。
#>
[CmdletBinding()]
param(
    [string]$Dir  = (Join-Path $HOME 'dotfiles'),
    [string]$Repo = 'kan/dotfiles',
    # テスト用: 関数定義だけ読み込み、末尾の main を実行しない（Pester が dot-source する）。
    [switch]$NoRun
)

$ErrorActionPreference = 'Stop'

# --- 表示ヘルパー -----------------------------------------------------------
function Write-Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [!] $Msg"  -ForegroundColor Yellow }

# コマンド存在判定の継ぎ目（テストでモックしやすいよう関数化）。
function Test-Command { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# --- 1. 前提整備 ------------------------------------------------------------
function Initialize-Prereq {
    # PS5.1 の既定は TLS1.0/1.1 のことがあり GitHub 等への接続が失敗する。
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # 既に TLS1.2+ 固定の環境等では設定不可。best-effort なので握り潰す。
        Write-Verbose "TLS1.2 の明示設定をスキップ: $_"
    }

    if (-not (Test-Command winget)) {
        # TODO(#7): App Installer 不在フォールバック（Git standalone 直 DL / App Installer 導入案内）
        throw 'winget (App Installer) が見つかりません。Microsoft Store の "アプリ インストーラー" を入れてから再実行してください。'
    }
    Write-Ok 'winget available'
}

# --- 2. 最小ツール導入（git / gh） ------------------------------------------
function Install-IfMissing {
    param([string]$Cmd, [string]$WingetId, [string]$Label)
    if (Test-Command $Cmd) {
        Write-Ok "$Label already installed"
        return
    }
    Write-Step "Installing $Label ($WingetId)..."
    # winget の既定スコープに任せる。Git.Git はマシンスコープのインストーラのため
    # ここで UAC が出ることがある（GitHub.cli は user スコープで完結しやすい）。
    & winget install -e --id $WingetId --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) { throw "$Label のインストールに失敗しました (winget exit $LASTEXITCODE)" }
}

# --- 3. PATH 再解決 ---------------------------------------------------------
function Update-SessionPath {
    # winget は現プロセスの PATH を更新しない。Machine + User を再合成して反映する。
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# --- 4. GitHub 認証 ---------------------------------------------------------
function Connect-GitHub {
    & gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'gh already authenticated'; return }
    Write-Step 'GitHub 認証（ブラウザ/デバイスフロー）...'
    & gh auth login --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { throw 'gh auth login に失敗しました' }
}

# --- 5. clone or pull -------------------------------------------------------
function Get-Repo {
    param([string]$RepoSlug, [string]$Target)
    if (Test-Path (Join-Path $Target '.git')) {
        Write-Step "既存 repo を更新: $Target"
        & git -C $Target pull --ff-only
    } else {
        Write-Step "clone $RepoSlug -> $Target"
        & gh repo clone $RepoSlug $Target
    }
    if ($LASTEXITCODE -ne 0) { throw "repo の取得に失敗しました ($RepoSlug)" }
}

# --- 6. 本体へ委譲 ----------------------------------------------------------
function Invoke-DotfilesWin {
    param([string]$Target)
    $entry = Join-Path $Target 'dotfiles-win.ps1'
    if (-not (Test-Path $entry)) { throw "dotfiles-win.ps1 が見つかりません: $entry" }
    Write-Step 'dotfiles-win setup を起動...'
    # .ps1 を直接 `&` で呼ぶとファイル実行扱いとなり ExecutionPolicy（既定 Restricted の
    # クライアントでは実行不可）に阻まれる。bootstrap 自体は irm|iex で免除されているが
    # 本体起動はプロセス限定の Bypass で確実に通す。
    & powershell -NoProfile -ExecutionPolicy Bypass -File $entry setup
    if ($LASTEXITCODE -ne 0) { throw "dotfiles-win setup が失敗しました (exit $LASTEXITCODE)" }
}

# --- main -------------------------------------------------------------------
function Invoke-Main {
    param([string]$RepoSlug, [string]$Target)
    Write-Host ''
    Write-Host 'booch-win bootstrap' -ForegroundColor Magenta
    Write-Host ''

    Initialize-Prereq
    Install-IfMissing -Cmd 'git' -WingetId 'Git.Git'    -Label 'Git'
    Install-IfMissing -Cmd 'gh'  -WingetId 'GitHub.cli' -Label 'GitHub CLI'
    Update-SessionPath
    Connect-GitHub
    Get-Repo -RepoSlug $RepoSlug -Target $Target
    Invoke-DotfilesWin -Target $Target

    Write-Host ''
    Write-Ok 'bootstrap 完了'
}

# -NoRun のときは関数定義だけ読み込む（Pester から dot-source してテストする用）。
if (-not $NoRun) {
    Invoke-Main -RepoSlug $Repo -Target $Dir
}
