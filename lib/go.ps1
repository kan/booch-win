#Requires -Version 5.1
#
# lib/go.ps1: 汎用機構 — go install によるツール導入
#
# dotfiles-win.ps1 から dot-source される。何を入れるか ($GoPackages) は
# 個人選択なので dotfiles-win.config.ps1。

# Go モジュールプロキシから最新版 (semver タグ) を返す (失敗時は '')。doctor の更新有無
# 表示用。$Module は "golang.org/x/tools/gopls" のようなモジュールパス。go コマンドを
# 使わないのは、go list がモジュールキャッシュとネットワークの両方に依存して待ち時間が
# 読めないため。$Script:ApiTimeoutSec / Get-EffectiveTimeout はエントリ側。
function Get-GoModuleLatestVersion {
    param([Parameter(Mandatory)][string]$Module)
    try {
        $resp = Invoke-RestMethod -Uri "https://proxy.golang.org/$Module/@latest" `
            -UseBasicParsing -TimeoutSec (Get-EffectiveTimeout $Script:ApiTimeoutSec)
        if ($resp.Version) { return [string]$resp.Version }
    } catch {}
    return ''
}

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
