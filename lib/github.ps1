#Requires -Version 5.1
#
# lib/github.ps1: 汎用機構 — GitHub Releases アクセス
#
# dotfiles-win.ps1 から dot-source される。
# $Script:ApiTimeoutSec / Get-EffectiveTimeout はエントリ側で定義される。
# codex.ps1 (タグ) と font.ps1 (asset) の双方がここ経由で releases/latest を引く。

# 指定 repo (owner/name) の releases/latest を取得して返す。失敗時は $null。
# 認証ヘッダ / リトライ等を足すなら唯一ここに集約する。
function Get-GitHubLatestRelease {
    param([Parameter(Mandatory)][string]$Repo)
    try {
        return Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$Repo/releases/latest" `
            -UseBasicParsing `
            -TimeoutSec (Get-EffectiveTimeout $Script:ApiTimeoutSec)
    } catch {}
    return $null
}

# releases/latest の tag_name を返す。失敗時は ''。
function Get-GitHubLatestReleaseTag {
    param([Parameter(Mandatory)][string]$Repo)
    $rel = Get-GitHubLatestRelease -Repo $Repo
    if ($rel -and $rel.tag_name) { return $rel.tag_name }
    return ''
}
