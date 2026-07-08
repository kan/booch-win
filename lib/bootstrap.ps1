#Requires -Version 5.1
#
# lib/bootstrap.ps1: 汎用機構 — booch-win ルート解決とロード対象 lib の一覧
#
# 消費側 (dotfiles-win 等) は、この 2 関数を使って booch-win を取り込む:
#   1. Resolve-BoochWinRoot でルートを決める (候補順は下記)。
#   2. Get-BoochWinLibFile が返す lib/*.ps1 を「呼び出し側スクリプトのトップレベルで」
#      dot-source する。
#
# なぜ「呼び出し側のトップレベルで dot-source」なのか:
#   lib/*.ps1 はエントリ側が定義する $Script: 変数 ($Script:SetupWinDir /
#   $Script:JobTimeoutSec / $Script:IsElevated 等) を参照する設計で、lib とエントリは
#   同一の script スコープを共有する必要がある。PowerShell では dot-source は「現在の
#   スコープ」に読み込むため、関数の中で dot-source すると関数ローカルに閉じて呼び出し元へ
#   伝播しない (定義された lib 関数もエントリから見えず、$Script: 共有も成立しない)。
#   したがって「ロードを 1 関数に隠蔽する Import-BoochWin」は成立せず、ロード
#   対象の一覧 (Get-BoochWinLibFile) を返し、dot-source はエントリのトップレベルで回す。
#   (トップレベルでの多段 dot-source なら $Script: 共有は保たれることを実機確認済み。)

# booch-win ルートを候補順に解決して返す。見つからなければ $null。
# 候補順 (Linux 側 dotfiles の BOOCH_ROOT 解決と対称):
#   1. env BOOCH_WIN_ROOT           明示上書き (開発中や別 clone の脱出ハッチ)
#   2. <DotfilesDir>/vendor/booch-win  submodule として取り込んだ場合
#   3. sibling <DotfilesDir>/../booch-win  開発時の隣接 clone
#   4. <SetupWinDir>                移行期間の後方互換 (setup-win/lib 同梱の旧構成)
# lib/common.ps1 の存在を「本物の booch-win か」の判定に使う。
function Resolve-BoochWinRoot {
    param([string]$DotfilesDir, [string]$SetupWinDir)
    if ($env:BOOCH_WIN_ROOT) {
        if (Test-Path -LiteralPath (Join-Path $env:BOOCH_WIN_ROOT 'lib\common.ps1')) {
            return $env:BOOCH_WIN_ROOT
        }
        throw "BOOCH_WIN_ROOT は指定されていますが lib/common.ps1 が見つかりません: $($env:BOOCH_WIN_ROOT)"
    }
    if ($DotfilesDir) {
        $vendor = Join-Path $DotfilesDir 'vendor\booch-win'
        if (Test-Path -LiteralPath (Join-Path $vendor 'lib\common.ps1')) { return $vendor }
        # 親が無い ($DotfilesDir がドライブ直下 'C:\' や単一セグメントの相対パス) 場合は
        # Split-Path -Parent が '' を返し Join-Path が throw する。sibling を諦めて次へ流す。
        $parent = Split-Path -Parent $DotfilesDir
        if ($parent) {
            $sibling = Join-Path $parent 'booch-win'
            if (Test-Path -LiteralPath (Join-Path $sibling 'lib\common.ps1')) { return $sibling }
        }
    }
    if ($SetupWinDir -and (Test-Path -LiteralPath (Join-Path $SetupWinDir 'lib\common.ps1'))) {
        return $SetupWinDir
    }
    return $null
}

# エントリが dot-source すべき lib/*.ps1 を順序づけて返す。
# - bootstrap.ps1 自身は除く (既に読み込まれている)。
# - apidoc.ps1 は除く (booch-win help 専用。setup/doctor/sync のエントリには不要で、
#   必要な bin/booch-win.ps1 が個別に dot-source する)。
# - common.ps1 を先頭にする (出力ヘルパー等、他が呼ぶ土台)。残りは name 昇順。
#   ※関数間の呼び出しは実行時解決なので厳密な順序依存は無いが、決定的に並べる。
function Get-BoochWinLibFile {
    param([Parameter(Mandatory)][string]$Root)
    $libDir = Join-Path $Root 'lib'
    if (-not (Test-Path -LiteralPath $libDir)) { return @() }
    $excluded = @('bootstrap.ps1', 'apidoc.ps1')
    $all = Get-ChildItem -Path $libDir -Filter '*.ps1' -File |
        Where-Object { $excluded -notcontains $_.Name }
    $common = @($all | Where-Object { $_.Name -eq 'common.ps1' })
    $rest = @($all | Where-Object { $_.Name -ne 'common.ps1' } | Sort-Object Name)
    # 注意: PowerShell は「要素 1 個の配列の return」を呼び出し境界でスカラーへ展開する。
    # そのため関数内で @() に包んでも、lib が 1 本だけのとき呼び出し側は文字列を受け取る。
    # 通常の消費 (foreach ($f in Get-BoochWinLibFile ...) { . $f }) はスカラーでも 1 回
    # 回るので問題ない。結果を $files[0] のように添字アクセスする側は @() で包むこと。
    ($common + $rest) | ForEach-Object { $_.FullName }
}
