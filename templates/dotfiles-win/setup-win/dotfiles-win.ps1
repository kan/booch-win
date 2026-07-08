#Requires -Version 5.1
#
# dotfiles-win.ps1: Windows セットアップ・同期スクリプト (booch-win ベースの最小雛形)
#
# booch-win scaffold で生成された骨組み。汎用機構 (winget/sync/doctor 等) は booch-win の
# lib/*.ps1 に任せ、ここには「どのコマンドで何を組み立てるか」だけを置く。個人固有の選択
# (同期対象・winget パッケージ・doctor 対象) は dotfiles-win.config.ps1 に書く。
#
# 直接 PowerShell から、または git bash の `dotfiles-win` ラッパー / `dotfiles-win.cmd`
# シム経由で呼べる。setup/sync の中身は用途に合わせて肉付けする (TODO 参照)。

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

# 日本語の出力が Windows の既定コードページ (cp932 等) で化けないよう UTF-8 に固定する
# (.cmd / ラッパーは powershell.exe を -NoProfile で起動するため profile 依存にできない)。
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

# lib が参照するタイムアウト設定 (Get-EffectiveTimeout が読む)。--no-timeout で無制限化。
$Script:JobTimeoutSec  = 120
$Script:ApiTimeoutSec  = 10
$Script:DisableTimeout = $false

# 引数解析: フラグを除いた最初の非フラグ語をサブコマンドにする (既定 setup)。
$Cmd = $null
foreach ($arg in @($Arguments)) {
    switch ($arg) {
        '--no-timeout' { $Script:DisableTimeout = $true }
        default { if (-not $Cmd) { $Cmd = $arg } }
    }
}
if (-not $Cmd) { $Cmd = 'setup' }

# ============================================================
# 環境の解決
# ============================================================

function Get-DotfilesDir {
    # 明示上書き → スクリプト位置 (setup-win/ の親) の .git → 既定 ~/dotfiles。
    if ($env:DOTFILES_WIN_DIR -and (Test-Path (Join-Path $env:DOTFILES_WIN_DIR '.git'))) {
        return $env:DOTFILES_WIN_DIR
    }
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    if ($scriptPath) {
        $parent = Split-Path -Parent (Split-Path -Parent $scriptPath)
        if ($parent -and (Test-Path (Join-Path $parent '.git'))) { return $parent }
    }
    $fallback = Join-Path $HOME 'dotfiles'
    if (Test-Path (Join-Path $fallback '.git')) { return $fallback }
    throw 'dotfiles リポジトリが見つかりません（環境変数 DOTFILES_WIN_DIR で指定できます）'
}

$Script:DotfilesDir = Get-DotfilesDir
$Script:SetupWinDir = Join-Path $Script:DotfilesDir 'setup-win'

# ============================================================
# booch-win (汎用機構) の読み込み
# ============================================================
# booch-win を BOOCH_WIN_ROOT → vendor/booch-win → sibling ../booch-win の順で解決し、
# その lib/bootstrap.ps1 を dot-source して Get-BoochWinLibFile が返す lib/*.ps1 を
# ★このスクリプトのトップレベルで dot-source する (lib はここで定義する $Script: を参照
# するため関数内ロード不可)。読み込む lib の一覧は booch-win 側が持つ。
$Script:BoochWinRoot = $null
if ($env:BOOCH_WIN_ROOT) {
    if (-not (Test-Path (Join-Path $env:BOOCH_WIN_ROOT 'lib\bootstrap.ps1'))) {
        throw "BOOCH_WIN_ROOT は指定されていますが lib/bootstrap.ps1 が見つかりません: $($env:BOOCH_WIN_ROOT)"
    }
    $Script:BoochWinRoot = $env:BOOCH_WIN_ROOT
} else {
    foreach ($cand in @(
            (Join-Path $Script:DotfilesDir 'vendor\booch-win'),
            (Join-Path (Split-Path -Parent $Script:DotfilesDir) 'booch-win')
        )) {
        if (Test-Path (Join-Path $cand 'lib\bootstrap.ps1')) {
            $Script:BoochWinRoot = $cand
            break
        }
    }
}
if (-not $Script:BoochWinRoot) {
    throw 'booch-win が見つかりません（vendor/booch-win を submodule 追加するか、環境変数 BOOCH_WIN_ROOT で指定してください）'
}
. (Join-Path (Join-Path $Script:BoochWinRoot 'lib') 'bootstrap.ps1')
$Script:LibFiles = @(Get-BoochWinLibFile -Root $Script:BoochWinRoot)
if ($Script:LibFiles.Count -eq 0) {
    throw "booch-win の lib が空です: $(Join-Path $Script:BoochWinRoot 'lib')"
}
foreach ($libFile in $Script:LibFiles) { . $libFile }

# ============================================================
# 個人選択 (config) の読み込み
# ============================================================
$Script:ConfigFile = Join-Path $Script:SetupWinDir 'dotfiles-win.config.ps1'
if (-not (Test-Path $Script:ConfigFile)) {
    throw "設定ファイルが見つかりません: $Script:ConfigFile"
}
. $Script:ConfigFile

# 昇格判定 (Test-IsElevated は booch-win lib/system.ps1)。winget 導入で参照する。
$Script:IsElevated = Test-IsElevated

# ============================================================
# サブコマンド
# ============================================================

function Show-Usage {
    Write-Host 'Usage: dotfiles-win [--no-timeout] [setup|doctor|sync|help]'
    Write-Host ''
    Write-Host '  setup   (default) winget パッケージ導入 + 設定ファイル同期'
    Write-Host '  doctor  ツールと設定ファイルの健全性チェック'
    Write-Host '  sync    設定ファイルの同期のみ (repo → 環境)'
    Write-Host '  help    このヘルプを表示'
    Write-Host ''
    Write-Host '  --no-timeout  Web リクエストのタイムアウトを無効化'
}

function Invoke-Doctor {
    Write-Host '=== dotfiles-win doctor ==='
    Write-Host ''
    Write-Host '--- tools ---'
    $missing = Show-ToolList -Tools $Script:DoctorTools
    Write-Host ''
    if ($missing) {
        Write-Host "一部ツールが未導入です。'dotfiles-win setup' で導入してください。"
        exit 1
    }
    Write-Host 'All tools are installed.'
}

function Invoke-Sync {
    Write-Host '=== config sync (repo → environment) ==='
    Write-Host ''
    foreach ($pair in $Script:SyncPairs) {
        $repoFile = Join-Path $Script:DotfilesDir $pair.Repo
        $destFile = $pair.Dest
        $label    = Get-SyncPairLabel $pair
        if (-not (Test-Path $repoFile)) { Write-Fail "${label}: repo file not found"; continue }
        $destDir = Split-Path -Parent $destFile
        if ($destDir -and -not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }
        if ((Test-Path $destFile) -and (Test-PairInSync $pair $repoFile $destFile)) {
            Write-Ok "${label}: up to date"
            continue
        }
        Deploy-Pair $pair $repoFile $destFile
        Write-Ok "${label}: deployed"
    }
    Write-Host ''
    # TODO: 雛形は repo → 環境の一方向 deploy のみ。双方向 (差分表示 + r/e/s 選択、
    # Import-Pair) が要るなら Test-PairInSync / Import-Pair を使って肉付けする。
    Write-Host 'Sync complete.'
}

function Invoke-Setup {
    Write-Host '=== dotfiles-win setup ==='
    Write-Host ''
    # TODO: 自己更新 (git pull) / UAC 昇格 / bin 配備などが要るなら足す。
    Install-WingetPackages -Packages $Script:WingetPackages
    Write-Host ''
    Invoke-Sync
}

# ============================================================
# ディスパッチ
# ============================================================
switch ($Cmd) {
    'setup'  { Invoke-Setup;  break }
    'doctor' { Invoke-Doctor; break }
    'sync'   { Invoke-Sync;   break }
    'help'   { Show-Usage;    break }
    default {
        Write-Host "unknown subcommand: $Cmd"
        Show-Usage
        exit 1
    }
}
