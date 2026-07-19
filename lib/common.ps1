#Requires -Version 5.1
#
# lib/common.ps1: 汎用機構 — 出力ヘルパーと共通ユーティリティ
#
# dotfiles-win.ps1 から dot-source される。個人固有の選択は含まない
# (それは dotfiles-win.config.ps1)。関心の分離。

# ============================================================
# 出力ヘルパー
# ============================================================

function Write-Info { param([string]$Msg) Write-Host '  → ' -NoNewline -ForegroundColor Cyan;   Write-Host $Msg }
function Write-Ok   { param([string]$Msg) Write-Host '  ✓ ' -NoNewline -ForegroundColor Green;  Write-Host $Msg }
function Write-Warn { param([string]$Msg) Write-Host '  ! ' -NoNewline -ForegroundColor Yellow; Write-Host $Msg }
function Write-Fail { param([string]$Msg) Write-Host '  ✗ ' -NoNewline -ForegroundColor Red;    Write-Host $Msg }

# 複数行テキスト (外部コマンドの出力など) を、空行を除いて Write-Info で 1 行ずつ出す。
function Write-InfoLines { # Text
    param([string]$Text)
    foreach ($l in ($Text -split "`r?`n" | Where-Object { $_.Trim() })) { Write-Info $l.Trim() }
}

function Write-Status {
    param(
        [string]$Label,
        [string]$Status,
        [ConsoleColor]$Color = 'White',
        [string]$Detail = '',
        # 既定幅。tools の最長ラベル `typescript-language-server` (26) と
        # claude plugins の最長ラベル (2 字インデント + プラグイン名) が収まり、
        # 余白 2 字が残る幅にする。config files 側は Get-SyncPairLabelWidth
        # (lib/sync.ps1) で自動算出した幅を渡す。
        [int]$LabelWidth = 28
    )
    Write-Host ('  {0}[' -f $Label.PadRight($LabelWidth)) -NoNewline
    Write-Host $Status -NoNewline -ForegroundColor $Color
    if ($Detail) {
        Write-Host "]  $Detail"
    } else {
        Write-Host ']'
    }
}

function Test-Cmd {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# native コマンドの stderr リダイレクトを安全に行うラッパー。
# PowerShell 5.1 では $ErrorActionPreference='Stop' のまま native コマンドに
# 2>&1 / 2>$null を付けると、stderr の 1 行目が NativeCommandError として
# terminating error になりスクリプトごと停止する。rustup / npm / winget は
# 正常時でも info・警告を stderr に書くため、成功していても落ちる。
# 実行中だけ EAP を Continue に緩めてこれを回避する。成否は例外ではなく
# $LASTEXITCODE で判定すること ($LASTEXITCODE はグローバルなので呼び出し後も
# そのまま参照できる)。
function Invoke-Quiet {
    param([Parameter(Mandatory)][scriptblock]$Block)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Block
    } finally {
        $ErrorActionPreference = $prevEap
    }
}
