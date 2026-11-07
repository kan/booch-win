#Requires -Version 5.1
#
# lib/github.ps1: 汎用機構 — GitHub Releases アクセス
#
# dotfiles-win.ps1 から dot-source される。
# $Script:ApiTimeoutSec / Get-EffectiveTimeout はエントリ側で定義される。
# codex.ps1 (タグ) と font.ps1 (asset) の双方がここ経由で releases/latest を引く。
# codex.ps1 はインストーラーの照合に使う資産の digest もここから取る。

# GitHub API の $Path (例: repos/owner/name/releases/latest) を GET して返す。失敗時は throw する。
# 認証ヘッダ / リトライ等を足すなら唯一ここに集約する。
function Invoke-GitHubApi {
    param([Parameter(Mandatory)][string]$Path)
    return Invoke-RestMethod `
        -Uri "https://api.github.com/$Path" `
        -UseBasicParsing `
        -TimeoutSec (Get-EffectiveTimeout $Script:ApiTimeoutSec)
}

# 指定 repo (owner/name) の releases/latest を取得して返す。失敗時は $null。
function Get-GitHubLatestRelease {
    param([Parameter(Mandatory)][string]$Repo)
    try {
        return Invoke-GitHubApi -Path "repos/$Repo/releases/latest"
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

# タグ $Tag のリリースの資産 $Name に Releases API が付ける SHA-256 の digest (16 進) を返す。
# 資産が無い、または digest が無い (古いリリース) ときは ''。API の取得に失敗したら throw する。
# 呼び出し側が「照合できない」と「照合する値が無い」を分けて扱えるようにするため。
function Get-GitHubReleaseAssetDigest {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Name
    )
    $rel = Invoke-GitHubApi -Path "repos/$Repo/releases/tags/$Tag"
    $asset = @($rel.assets) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($asset -and ([string]$asset.digest) -match '^sha256:([0-9a-fA-F]{64})$') {
        return $Matches[1].ToLowerInvariant()
    }
    return ''
}
