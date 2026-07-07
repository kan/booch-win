#Requires -Version 5.1
#
# lib/download.ps1: 汎用機構 — ファイルダウンロード
#
# dotfiles-win.ps1 から dot-source される。詳細は kan/dotfiles#6。

# 大きめのファイルを Uri から OutFile にダウンロードする。
# Windows PowerShell 5.1 の Invoke-WebRequest -TimeoutSec は
# HttpWebRequest.Timeout / ReadWriteTimeout (= 1 回の read 操作ごと)
# にマップされていて「全体の経過時間」を制限しないため、低速で
# データが流れ続けている間は永遠にタイムアウトしない。加えて
# -OutFile + progress 計算で極端に遅くなる既知バグもあるため、
# Windows 10 1803+ 同梱の curl.exe があればそちらを優先する。
# (Linux 版の curl --max-time と同じ感覚で扱える)
function Invoke-Download {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$OutFile,
        [int]$TimeoutSec = 120
    )

    $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curlExe) {
        $curlArgs = @('-fsSL', '--retry', '3', '-o', $OutFile)
        if ($TimeoutSec -gt 0) {
            $curlArgs += @('--max-time', "$TimeoutSec")
        }
        $curlArgs += $Uri
        & $curlExe @curlArgs
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed (exit $LASTEXITCODE) for $Uri"
        }
        return
    }

    $progPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $iwrParams = @{
            Uri             = $Uri
            OutFile         = $OutFile
            UseBasicParsing = $true
        }
        if ($TimeoutSec -gt 0) { $iwrParams.TimeoutSec = $TimeoutSec }
        Invoke-WebRequest @iwrParams
    } finally {
        $ProgressPreference = $progPref
    }
}
