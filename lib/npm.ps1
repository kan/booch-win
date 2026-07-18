#Requires -Version 5.1
#
# lib/npm.ps1: 汎用機構 — npm global パッケージ導入
#
# dotfiles-win.ps1 から dot-source される。何を入れるか ($NpmGlobalPackages)
# は個人選択なので dotfiles-win.config.ps1。

# npm で global にパッケージ群を導入/更新する。$VerifyCmd が導入後に
# 解決できれば成功とみなす。node/npm は winget (OpenJS.NodeJS.LTS) で導入済み前提。
function Install-NpmGlobal {
    param(
        [Parameter(Mandatory)][string[]]$Packages,
        [Parameter(Mandatory)][string]$VerifyCmd,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Cmd 'npm')) {
        Write-Fail "npm が見つからないため $Label をインストールできません"
        return
    }
    Write-Info "Installing/updating ${Label}..."
    # npm は警告 / 進捗を stderr に書くため Invoke-Quiet で無害化する
    Invoke-Quiet { & npm install -g @Packages --no-fund --no-audit 2>&1 | Out-Null }
    # 成否は npm の exit code で判定する。Test-Cmd だけだと、install が失敗しても過去に
    # 入れた同名コマンドが PATH に残っていれば「成功」と誤報告してしまう。
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "${Label}: npm install failed (exit $LASTEXITCODE)"
    } elseif (Test-Cmd $VerifyCmd) {
        Write-Ok "${Label}: installed/updated"
    } else {
        Write-Fail "${Label}: install succeeded but $VerifyCmd not found (PATH を確認してください)"
    }
}
