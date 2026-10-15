#Requires -Version 5.1
#
# lib/store.ps1: 汎用機構 — Microsoft Store の自動更新ポリシーの確認と停止
#
# dotfiles-win.ps1 から dot-source される。Store の自動更新は、PC がスタンバイ中のアイドル時間にも
# WSL 本体などを更新し、その途中で WSL の VM が止まる。止めるかどうかは消費側の config が決める。
# Store 全体の自動更新が止まり、WSL 以外の Store アプリも更新されなくなるので、booch-win から既定で
# 呼ぶことはしない。WSL 本体の更新は lib/wsl.ps1 の Get-WslUpdateStatus / Update-WslPackage。
# 依存: Test-IsElevated (lib/system.ps1)。entry が全 lib をまとめて dot-source する。

$Script:StorePolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
# ポリシー「Turn off Automatic Download and Install of updates」の値。2 = 自動更新しない、4 = する。
$Script:StoreAutoDownloadOff = 2

# ポリシーの AutoDownload の値。未設定なら $null。
function Get-StoreAutoDownloadPolicy {
    return (Get-ItemProperty -LiteralPath $Script:StorePolicyKey -ErrorAction SilentlyContinue).AutoDownload
}

# Store の自動更新がポリシーで止まっているか。
function Test-StoreAutoUpdateDisabled {
    return ((Get-StoreAutoDownloadPolicy) -eq $Script:StoreAutoDownloadOff)
}

# Store の自動更新を止めるポリシー (AutoDownload = 2) を冪等に設定し、結果の状態文字列を返す。
# HKLM なので昇格が要る。書き込みに失敗したら throw する。
#   'already'     既に止まっている (何も書かない)
#   'needs-admin' 管理者権限が無いため実行できない
#   'disabled'    止めた
function Disable-StoreAutoUpdate {
    if (Test-StoreAutoUpdateDisabled) { return 'already' }
    if (-not (Test-IsElevated)) { return 'needs-admin' }
    # 既存のキーに New-Item -Force をかけると作り直されるので、無いときだけ作る。
    if (-not (Test-Path -LiteralPath $Script:StorePolicyKey)) {
        New-Item -Path $Script:StorePolicyKey -Force -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -LiteralPath $Script:StorePolicyKey -Name 'AutoDownload' -Type DWord `
        -Value $Script:StoreAutoDownloadOff -ErrorAction Stop
    return 'disabled'
}
