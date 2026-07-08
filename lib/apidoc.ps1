#Requires -Version 5.1
#
# lib/apidoc.ps1: 汎用機構 — lib/*.ps1 のヘッダと公開関数を抽出して help を組み立てる
#
# Linux 側 booch の lib/apidoc.sh に対応する。`booch-win help [name]` 用に、各モジュールの
# 「冒頭ヘッダコメント」と「公開関数シグネチャ」をソースから抽出して整形する。API の正本は
# 各ファイルの冒頭コメントと関数宣言なので、本ヘルパーはそれを読み出して並べるだけで、
# 説明を二重管理しない (正本＝ソース)。
#
# 使い方:
#   . "$BoochWinRoot/lib/apidoc.ps1"
#   Show-BoochWinApiIndex               # 全モジュールの一覧 (name + 1 行説明)
#   Show-BoochWinApiModule -Name winget # winget.ps1 のヘッダ全文 + 公開関数シグネチャ
#
# 抽出規約:
#   - ヘッダ: 先頭の `#Requires` 行を飛ばし、以降の連続するコメント行を「# 」を外して取る
#     (最初の非コメント行で打ち切り)。ファイル冒頭のコメントブロックがそのまま該当する。
#   - 1 行説明: ヘッダ最初の非空行から `lib/<name>.ps1:` プレフィックスを外したもの。
#   - 公開関数: トップレベルの関数定義を AST で列挙する (関数内のネスト定義は出さない)。
#     PowerShell は dot-source ですべての関数が見えるため、prefix ではなくトップレベルか
#     どうかで公開面を判断する。型制約付き引数は `[type]$name` として併記する。

# 既定の探索ルート。dot-source 時は本ファイル (lib/) の親をルートとみなす。CLI からは
# -Root で明示上書きできる。
$Script:BoochWinApiDocRoot = Split-Path -Parent $PSScriptRoot

# ファイル冒頭のヘッダコメントブロックを「# 」を外して行配列で返す。#Requires は除く。
function Get-BoochWinModuleHeader {
    param([Parameter(Mandatory)][string]$Path)
    $lines = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path))
    $out = New-Object System.Collections.Generic.List[string]
    $started = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*#Requires') { continue }
        if ($line -match '^\s*#') {
            $started = $true
            $out.Add(($line -replace '^\s*#[ ]?', ''))
        } elseif ($started) {
            break
        } elseif ($line.Trim().Length -ne 0) {
            break
        }
    }
    return $out.ToArray()
}

# ヘッダ最初の非空行を 1 行説明として返す (lib/<name>.ps1: プレフィックスは外す)。
function Get-BoochWinModuleSummary {
    param([Parameter(Mandatory)][string]$Path)
    $first = Get-BoochWinModuleHeader -Path $Path |
        Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1
    if (-not $first) { return '' }
    return ($first -replace '^\s*(lib/)?[\w.-]+\.ps1:\s*', '')
}

# トップレベル関数のシグネチャを `Name([type]$a, $b)` 形式で列挙する (ソース出現順)。
function Get-BoochWinModuleFunctions {
    param([Parameter(Mandatory)][string]$Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $Path).Path, [ref]$null, [ref]$errors)
    # ParseFile は構文エラーでも「エラーまでに読めた部分 AST」を返す (非 null)。
    # 壊れたファイルの中途半端なシグネチャを出すと誤解を招くので、エラーがあれば
    # 何も列挙しない (help は正しいソースからのみ生成する)。
    if ($errors -or -not $ast) { return @() }
    # searchNestedScriptBlocks = $false: 関数本体 (ネスト scriptblock) には降りないので
    # トップレベル定義だけが得られる。
    $funcs = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $false)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($fn in $funcs) {
        if ($fn.Parameters) {
            $params = $fn.Parameters
        } elseif ($fn.Body.ParamBlock) {
            $params = $fn.Body.ParamBlock.Parameters
        } else {
            $params = @()
        }
        $sig = foreach ($p in $params) {
            $name = '$' + $p.Name.VariablePath.UserPath
            $tc = $p.Attributes |
                Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } |
                Select-Object -First 1
            if ($tc) { ('[{0}]{1}' -f $tc.TypeName.Name, $name) } else { $name }
        }
        $out.Add(('{0}({1})' -f $fn.Name, ($sig -join ', ')))
    }
    return $out.ToArray()
}

# name (拡張子なし) を lib/<name>.ps1 に解決してパスを返す。無ければ $null。
function Resolve-BoochWinModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Root = $Script:BoochWinApiDocRoot
    )
    $cand = Join-Path (Join-Path $Root 'lib') ($Name + '.ps1')
    if (Test-Path -LiteralPath $cand) { return (Resolve-Path -LiteralPath $cand).Path }
    return $null
}

# lib/*.ps1 を name 昇順で {Name; Path} の配列にして返す。
function Get-BoochWinModuleList {
    param([string]$Root = $Script:BoochWinApiDocRoot)
    $libDir = Join-Path $Root 'lib'
    if (-not (Test-Path -LiteralPath $libDir)) { return @() }
    Get-ChildItem -Path $libDir -Filter '*.ps1' -File |
        Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ Name = $_.BaseName; Path = $_.FullName } }
}

# モジュール索引 (name + 1 行説明) を表示する。
function Show-BoochWinApiIndex {
    param([string]$Root = $Script:BoochWinApiDocRoot)
    Write-Host 'モジュール一覧 (詳細は booch-win help <name>):'
    Write-Host ''
    Write-Host 'ライブラリ (lib/):'
    foreach ($m in Get-BoochWinModuleList -Root $Root) {
        $summary = Get-BoochWinModuleSummary -Path $m.Path
        Write-Host ('  {0}  {1}' -f $m.Name.PadRight(12), $summary)
    }
}

# 1 モジュールの詳細 (ヘッダ全文 + 公開関数シグネチャ) を表示する。
# 見つかれば $true、不明なら警告して $false を返す (呼び出し側が exit code に使う)。
function Show-BoochWinApiModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Root = $Script:BoochWinApiDocRoot
    )
    $file = Resolve-BoochWinModule -Name $Name -Root $Root
    if (-not $file) {
        Write-Host ('booch-win help: 不明なモジュール: {0}' -f $Name)
        Write-Host '  booch-win help で一覧を表示'
        return $false
    }
    # $file は Resolve-BoochWinModule で絶対パス化済み。相対/短縮の -Root override でも
    # 正しく切り出せるよう $Root も正規化してからプレフィックスを外す。
    $rootFull = (Resolve-Path -LiteralPath $Root).Path
    $rel = $file.Substring($rootFull.Length).TrimStart('\', '/')
    Write-Host ('== {0} ({1}) ==' -f $Name, $rel)
    Write-Host ''
    # ヘッダ先頭の空行 (冒頭の `#` 区切り) は落として詰めて表示する。
    $header = @(Get-BoochWinModuleHeader -Path $file)
    $i = 0
    while ($i -lt $header.Count -and $header[$i].Trim().Length -eq 0) { $i++ }
    for (; $i -lt $header.Count; $i++) { Write-Host $header[$i] }
    $fns = Get-BoochWinModuleFunctions -Path $file
    if ($fns.Count -gt 0) {
        Write-Host ''
        Write-Host '公開関数:'
        foreach ($f in $fns) { Write-Host ('  ' + $f) }
    }
    return $true
}
