<#
.SYNOPSIS
    booch-win bootstrap: 素の Windows から private dotfiles を入れ、dotfiles-win setup を起動する。

.DESCRIPTION
    git すら無い Windows から「dotfiles-win setup が走る状態」までを 1 コマンドで持っていく。
    winget で git / gh を入れ、gh のブラウザ認証で private repo を clone し、本体へ委譲する。

    設定はすべて環境変数で渡す（下記）。booch-win は汎用ツールなので特定リポジトリを
    既定に埋め込まない。param ブロックを持たないのは、Windows PowerShell 5.1 の
    `irm | iex`（文字列を Invoke-Expression で評価）が、版によって先頭の param(...) /
    [CmdletBinding()] をパースエラー（「予期しない属性」「代入式が無効」）にするため。
    env だけで動かせば、どの 5.1 ビルドでも irm|iex が確実に通る。

      BOOCH_WIN_REPO   取り込む dotfiles (owner/name)。必須（未指定なら明示エラー）
      BOOCH_WIN_DIR    clone 先（既定: ~/dotfiles）

    Windows PowerShell 5.1 で動く構文に限定する（素の環境に pwsh は無い）。
    冪等: 各ステップ「無ければ入れる / 既存なら pull」。

.EXAMPLE
    $env:BOOCH_WIN_REPO = 'youraccount/dotfiles'
    irm https://raw.githubusercontent.com/kan/booch-win/main/win.ps1 | iex

.EXAMPLE
    # clone 先も変える場合
    $env:BOOCH_WIN_REPO = 'youraccount/dotfiles'; $env:BOOCH_WIN_DIR = 'D:\dev\dotfiles'
    irm https://raw.githubusercontent.com/kan/booch-win/main/win.ps1 | iex

.NOTES
    STATUS: スケルトン（未検証）。クリーンに近い環境でのスモークは #7 で実施する。
#>
# 設定は環境変数で受ける（param ブロックを持たない）。理由は上のヘルプ参照 — PS5.1 の
# irm|iex は版によって先頭 param(...) をパースできず「代入式が無効」等で落ちるため、
# param に依存せず env だけで動かす。
$Dir   = if ($env:BOOCH_WIN_DIR) { $env:BOOCH_WIN_DIR } else { Join-Path $HOME 'dotfiles' }
$Repo  = $env:BOOCH_WIN_REPO
# BOOCH_WIN_NORUN=1 なら main を実行せず関数定義だけ読み込む（Pester が dot-source する用）。
$NoRun = ($env:BOOCH_WIN_NORUN -eq '1')

$ErrorActionPreference = 'Stop'

# --- 表示ヘルパー -----------------------------------------------------------
function Write-Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [!] $Msg"  -ForegroundColor Yellow }

# コマンド存在判定の継ぎ目（テストでモックしやすいよう関数化）。
function Test-Command { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# native コマンド（winget / gh / git / powershell）実行の継ぎ目。PS5.1 では
# $ErrorActionPreference='Stop' のまま native が stderr に書くと、2>$null を付けても
# NativeCommandError で terminating になり、$LASTEXITCODE を見る前に落ちる
# （例: 未ログイン時の gh auth status の stderr）。実行中だけ Continue に緩める。
# 成否は $LASTEXITCODE で見る（グローバルなので呼び出し後も参照できる）。
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Script)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Script } finally { $ErrorActionPreference = $prev }
}

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
    Invoke-Native { & winget install -e --id $WingetId --accept-source-agreements --accept-package-agreements --silent }
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
    Invoke-Native { & gh auth status 2>$null | Out-Null }
    if ($LASTEXITCODE -eq 0) { Write-Ok 'gh already authenticated'; return }
    Write-Step 'GitHub 認証（ブラウザ/デバイスフロー）...'
    Invoke-Native { & gh auth login --git-protocol https --web }
    if ($LASTEXITCODE -ne 0) { throw 'gh auth login に失敗しました' }
}

# --- 5. clone or pull -------------------------------------------------------
function Get-Repo {
    param([string]$RepoSlug, [string]$Target)
    if (Test-Path (Join-Path $Target '.git')) {
        Write-Step "既存 repo を更新: $Target"
        Invoke-Native { & git -C $Target pull --ff-only }
    } else {
        Write-Step "clone $RepoSlug -> $Target"
        # `--` 以降は git clone へ転送される。委譲先 dotfiles-win.ps1 は
        # submodule (vendor/booch-win 等) を自前で取得せず、無ければ throw するため
        # clone 時に必ず recurse する。
        Invoke-Native { & gh repo clone $RepoSlug $Target -- --recurse-submodules }
    }
    if ($LASTEXITCODE -ne 0) { throw "repo の取得に失敗しました ($RepoSlug)" }
    # submodule を初期化・更新する。clone は上で --recurse-submodules 済みなので
    # no-op、pull 経路 (既存 repo 更新) ではここが実質の取得になる。これが無いと
    # dotfiles-win.ps1 が booch-win を解決できず「booch-win が見つかりません」で止まる。
    Write-Step 'submodule を初期化・更新...'
    Invoke-Native { & git -C $Target submodule update --init --recursive }
    if ($LASTEXITCODE -ne 0) { throw "submodule の取得に失敗しました ($RepoSlug)" }
}

# --- 6. 本体へ委譲 ----------------------------------------------------------
function Invoke-DotfilesWin {
    param([string]$Target)
    $entry = Join-Path (Join-Path $Target 'setup-win') 'dotfiles-win.ps1'
    if (-not (Test-Path $entry)) { throw "setup-win/dotfiles-win.ps1 が見つかりません: $entry" }
    Write-Step 'dotfiles-win setup を起動...'
    # .ps1 を直接 `&` で呼ぶとファイル実行扱いとなり ExecutionPolicy（既定 Restricted の
    # クライアントでは実行不可）に阻まれる。bootstrap 自体は irm|iex で免除されているが
    # 本体起動はプロセス限定の Bypass で確実に通す。
    Invoke-Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $entry setup }
    if ($LASTEXITCODE -ne 0) { throw "dotfiles-win setup が失敗しました (exit $LASTEXITCODE)" }
}

# --- main -------------------------------------------------------------------
function Invoke-Main {
    param([string]$RepoSlug, [string]$Target)
    if (-not $RepoSlug) {
        throw '対象 dotfiles リポジトリが未指定です。環境変数 BOOCH_WIN_REPO=<owner>/<name> を設定してから実行してください。'
    }
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

# BOOCH_WIN_NORUN=1 のときは関数定義だけ読み込む（Pester から dot-source してテストする用）。
if (-not $NoRun) {
    Invoke-Main -RepoSlug $Repo -Target $Dir
}
