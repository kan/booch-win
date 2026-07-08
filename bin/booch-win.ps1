#Requires -Version 5.1
#
# bin/booch-win.ps1: booch-win 補助 CLI (help / version)。
#
# Linux 側 booch の bin/booch に対応する。本体はあくまで dot-source して使うライブラリで、
# この CLI は補助。公開 API をソースを開かずに引けるようにする help と、VERSION を返す
# version を提供する。
#
# 使い方:
#   ./bin/booch-win.ps1 help            このヘルプ + モジュール一覧
#   ./bin/booch-win.ps1 help <name>     モジュール (例: winget / sync) の API
#   ./bin/booch-win.ps1 version         バージョン (VERSION ファイル) を表示

$ErrorActionPreference = 'Stop'

# bin/ の親を booch-win ルートとみなす。
$Script:BoochWinRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $Script:BoochWinRoot 'lib') 'apidoc.ps1')

function Show-BoochWinUsage {
    Write-Host 'booch-win - Windows 開発環境ブートストラップ基盤'
    Write-Host ''
    Write-Host '使い方:'
    Write-Host '  booch-win help            このヘルプ + モジュール一覧を表示する'
    Write-Host '  booch-win help <name>     モジュール (例: winget / sync) の API を表示する'
    Write-Host '  booch-win version         バージョンを表示する'
    Write-Host ''
    Write-Host 'ライブラリとしての使い方は README.md を参照。'
}

$cmd = if ($args.Count -ge 1) { [string]$args[0] } else { '' }

switch -Regex ($cmd) {
    '^(help|-h|--help)$' {
        if ($args.Count -ge 2) {
            if (-not (Show-BoochWinApiModule -Name ([string]$args[1]) -Root $Script:BoochWinRoot)) {
                exit 1
            }
        } else {
            Show-BoochWinUsage
            Write-Host ''
            Show-BoochWinApiIndex -Root $Script:BoochWinRoot
        }
        break
    }
    '^(version|-V|--version)$' {
        $versionFile = Join-Path $Script:BoochWinRoot 'VERSION'
        $raw = if (Test-Path -LiteralPath $versionFile) {
            Get-Content -LiteralPath $versionFile -Raw
        } else { $null }
        # 空 (0 バイト) の VERSION は Get-Content -Raw が $null を返すため .Trim() で
        # 落ちる。存在だけでなく中身も見る。
        if ($raw) {
            Write-Host $raw.Trim()
        } else {
            Write-Host 'booch-win: VERSION 未設定'
        }
        break
    }
    '^$' {
        Show-BoochWinUsage
        exit 1
    }
    default {
        Write-Host ('booch-win: 不明なサブコマンド: {0}' -f $cmd)
        Write-Host '  booch-win help でヘルプを表示'
        exit 1
    }
}
