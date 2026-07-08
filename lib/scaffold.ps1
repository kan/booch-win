#Requires -Version 5.1
#
# lib/scaffold.ps1: 汎用機構 — booch-win を使う repo の雛形生成
#
# templates/<kind>/ を -Path へ相対パスを保って複製する。既存ファイルは上書きしない
# (冪等。-Force で上書き)。git は触らない (submodule 追加などの手順は生成物の README に案内)。
# Linux 側 booch の lib/scaffold.sh に対応する。

# templates/ の探索ルート。dot-source 時は本ファイル (lib/) の親をルートとみなす。
$Script:BoochWinScaffoldRoot = Split-Path -Parent $PSScriptRoot

# 生成できる雛形の種類 (templates/ 直下のディレクトリ名) を列挙する。
function Get-BoochWinScaffoldKind {
    param([string]$Root = $Script:BoochWinScaffoldRoot)
    $templatesDir = Join-Path $Root 'templates'
    if (-not (Test-Path -LiteralPath $templatesDir)) { return @() }
    Get-ChildItem -LiteralPath $templatesDir -Directory | ForEach-Object { $_.Name }
}

# templates/<Kind> を -Path へ複製する。返り値は @{ Kind; Path; Created; Skipped }。
function New-BoochWinScaffold {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force,
        [string]$Root = $Script:BoochWinScaffoldRoot
    )
    $templateDir = Join-Path (Join-Path $Root 'templates') $Kind
    if (-not (Test-Path -LiteralPath $templateDir)) {
        throw "不明な雛形: $Kind (templates/$Kind がありません)"
    }
    # 相対/非正規な -Root でも $f.FullName (絶対・正規化済み) の接頭辞と一致するよう、
    # templateDir も絶対パスへ正規化してから Substring の基点にする。
    $templateDir = (Resolve-Path -LiteralPath $templateDir).Path
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $created = 0
    $skipped = 0
    # -Force で .gitattributes 等のドットファイルも拾う。相対パスを保って複製する
    # (パスに [ ] が含まれても誤ってワイルドカード解釈しないよう -LiteralPath)。
    foreach ($f in (Get-ChildItem -LiteralPath $templateDir -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($templateDir.Length).TrimStart('\', '/')
        $dest = Join-Path $Path $rel
        $destDir = Split-Path -Parent $dest
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $dest) -and -not $Force) {
            Write-Host ('  skip (exists): {0}' -f $rel)
            $skipped++
            continue
        }
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        Write-Host ('  create: {0}' -f $rel)
        $created++
    }
    return [pscustomobject]@{ Kind = $Kind; Path = $Path; Created = $created; Skipped = $skipped }
}
