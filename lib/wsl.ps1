#Requires -Version 5.1
#
# lib/wsl.ps1: 汎用機構 — WSL2 とディストロの導入
#
# dotfiles-win.ps1 から dot-source される。どのディストロを入れるかは個人選択なので消費側の
# config が持ち、ここは wsl.exe を叩く「やり方」だけを提供する。案内文言は状態を返して
# 消費側に任せる (次の手順は利用側の運用に依るため)。
#
# 公開 API:
#   Get-WslDistros()            導入済みディストロ名の配列
#   Install-WslDistro(Distro)   WSL2 + 指定ディストロを導入し、結果の状態文字列を返す

# 導入済み WSL ディストロ名の配列。wsl.exe は一覧を UTF-16 で出すため、コンソールの
# 出力エンコーディング次第で 1 文字ごとに null が挟まる。null を除いてから行に分ける。
function Get-WslDistros {
    $raw = Invoke-Quiet { & wsl.exe --list --quiet 2>&1 | Out-String }
    return @(($raw -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# WSL2 + $Distro を導入する (既定バージョン 2 + wsl --install -d ... --no-launch)。
# --no-launch にするのは初回起動のユーザー作成が対話のため (呼び出し側が案内する)。
# wsl --install は機能有効化に管理者権限が要る。初回は機能有効化だけ済んで WSL の再起動を
# 待つ状態になることがあり、その場合ディストロはまだ現れない。状態を返して呼び出し側が
# 案内を出し分ける:
#   'already'       既に導入済み (何もしない)
#   'needs-admin'   管理者権限が無いため実行できない
#   'installed'     ディストロ導入まで完了
#   'needs-restart' 機能は有効化したが WSL の再起動が要る (再実行で続きから)
function Install-WslDistro { # Distro
    param([string]$Distro)
    if ((Get-WslDistros) -contains $Distro) { return 'already' }
    if (-not (Test-IsElevated)) { return 'needs-admin' }
    # wsl.exe は正常時も stderr へ進捗を書くため、EAP を緩めて native の停止を避ける
    # (PS5.1 では Stop のまま native の stderr が NativeCommandError になる)。
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & wsl.exe --set-default-version 2 | Out-Null
        & wsl.exe --install -d $Distro --no-launch
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ((Get-WslDistros) -contains $Distro) { return 'installed' }
    return 'needs-restart'
}
