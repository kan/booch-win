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

# 端末に表示したときの桁数を返す。**文字数ではなく表示幅**で、East Asian Wide / Fullwidth
# (漢字・かな・全角記号など) は 2 桁として数える。
#
# 桁揃えに .NET の文字数 ($s.Length / PadRight) を使うと、日本語を含むラベルだけ右へずれる
# (全角 1 文字が 1 文字と数えられるのに端末では 2 桁を占めるため)。ラベルに日本語を使いたい
# 消費側のために、幅の計算をここへ集約する。
#
# サロゲートペア (絵文字など) は .NET の char 2 個で表現されるので、そのままだと 2 桁と
# 数えてしまう。ペアの下位側 (low surrogate) を 0 桁として飛ばし、上位側で幅を決める。
# 曖昧幅 (U+2192 → や U+2714 ✔ など) は 1 桁扱い —— Windows Terminal / WSL の既定描画に合わせる。
function Get-BoochWinDisplayWidth { # Text
    param([string]$Text)
    if (-not $Text) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if ([char]::IsLowSurrogate($ch)) { continue }
        if (($c -ge 0x1100 -and $c -le 0x115F) -or   # Hangul Jamo
            ($c -ge 0x2E80 -and $c -le 0x303E) -or   # CJK 部首補助〜CJK 記号・句読点
            ($c -ge 0x3041 -and $c -le 0x33FF) -or   # ひらがな〜CJK 互換
            ($c -ge 0x3400 -and $c -le 0x4DBF) -or   # CJK 統合漢字拡張 A
            ($c -ge 0x4E00 -and $c -le 0x9FFF) -or   # CJK 統合漢字
            ($c -ge 0xA000 -and $c -le 0xA4CF) -or   # イ文字
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or   # ハングル音節
            ($c -ge 0xD800 -and $c -le 0xDBFF) -or   # 上位サロゲート (絵文字等は 2 桁)
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or   # CJK 互換漢字
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or   # CJK 互換形・小字形
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or   # 全角英数・記号
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) {    # 全角通貨記号
            $w += 2
        } else {
            $w += 1
        }
    }
    return $w
}

# 表示幅で右詰めする (足りない分を空白で埋める)。既に幅を超えていれば埋めない。
function Format-BoochWinPadRight { # Text Width
    param([string]$Text, [int]$Width)
    $pad = $Width - (Get-BoochWinDisplayWidth $Text)
    if ($pad -le 0) { return $Text }
    return $Text + (' ' * $pad)
}

function Write-Status {
    param(
        [string]$Label,
        [string]$Status,
        [ConsoleColor]$Color = 'White',
        [string]$Detail = '',
        # 既定幅。次の最長ラベルが収まり、余白 2 字が残る幅にする。
        #   - tools: `typescript-language-server` (26)
        #   - claude plugins: Show-ClaudePlugins の Indent + プラグイン名。config dir 行を
        #     挟む消費側の 4 字インデント + 17 字でも 21
        #   - claude marketplaces: Show-ClaudeMarketplaces の 4 字インデント + `mkt:` +
        #     `claude-plugins-official` = 31 ←**これが最長**
        # 幅を超えたラベルは埋められず、その行だけ [OK] がラベルに密着する。行を足すときは
        # ここの計算も更新すること。config files 側は Get-SyncPairLabelWidth (lib/sync.ps1) で
        # 自動算出した幅を渡す。
        # **桁数は表示幅で数える** (PadRight ではなく Format-BoochWinPadRight)。日本語ラベルを
        # 文字数で埋めると、その行だけ [OK] が右へずれる。
        [int]$LabelWidth = 33
    )
    Write-Host ('  {0}[' -f (Format-BoochWinPadRight $Label $LabelWidth)) -NoNewline
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
