#Requires -Version 5.1
#
# lib/go.ps1: 汎用機構 — go install によるツール導入
#
# dotfiles-win.ps1 から dot-source される。何を入れるか ($GoPackages) は
# 個人選択なので dotfiles-win.config.ps1。

# go install <Package> でツールを導入/更新する。go が無ければ失敗を表示。
function Install-GoPackage {
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Cmd,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Cmd 'go')) {
        Write-Fail "go が見つからないため $Label をインストールできません"
        return
    }
    if (Test-Cmd $Cmd) {
        Write-Ok "${Label}: already installed"
        Write-Info 'Updating...'
    } else {
        Write-Info "Installing ${Label}..."
    }
    & go install $Package
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "${Label}: installed/updated"
    } else {
        Write-Fail "${Label}: install failed"
    }
}
