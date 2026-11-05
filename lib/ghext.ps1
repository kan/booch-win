#Requires -Version 5.1
#
# lib/ghext.ps1: 汎用機構 — gh (GitHub CLI) の拡張の導入と診断
#
# dotfiles-win.ps1 から dot-source される。どの拡張を入れるか (owner/repo の一覧) は
# 個人選択なので利用側の config が持つ。gh 本体は winget (GitHub.cli) で導入済みの前提。
# doctor の表示は lib/doctor.ps1 の Show-ToolList を使う。
#
# 版は固定せず、上流の最新を追う。一覧から外した拡張は消さない (`gh extension remove <name>`
# で手で消す)。版の比較が成り立つのは、リリースを持つ binary 拡張だけ (script 拡張は
# `gh extension list` の 3 列目がコミット SHA になる)。一覧には binary 拡張を書く。

# `gh extension list` の出力を行の配列で返す (gh が無い・失敗したときは空)。
# 呼び出し側は 1 回だけ取って Get-GhExtensionVersion に使い回す。テストではこの関数を差し替える。
function Get-GhExtensionList {
    if (-not (Test-Cmd 'gh')) { return @() }
    $out = Invoke-Quiet { & gh extension list 2>$null }
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($out | Where-Object { $_ })
}

# 導入済み拡張の版 (タグ) を返す。未導入なら ''。$List は Get-GhExtensionList の結果。
# 非端末での `gh extension list` はタブ区切りで「表示名 / owner/repo / 版」を出す。
function Get-GhExtensionVersion {
    param(
        [string[]]$List = @(),
        [Parameter(Mandatory)][string]$Repo
    )
    foreach ($line in $List) {
        $cols = $line -split "`t"
        if ($cols.Count -ge 3 -and $cols[1] -eq $Repo) { return $cols[2].Trim() }
    }
    return ''
}

# 表示用のラベル ('github/gh-actions-lock' → 'gh actions-lock')。
function Get-GhExtensionLabel {
    param([Parameter(Mandatory)][string]$Repo)
    return 'gh ' + (($Repo -split '/')[-1] -replace '^gh-', '')
}

# gh が github.com で認証済み (API を使える) かを返す。gh があることは呼び出し側が確かめる。
# --hostname と --active で github.com の使用中のアカウントだけを見る。付けないと、別ホスト (GHES)
# や使っていないアカウントの期限切れでも終了コード 1 になる。テストではこの関数を差し替える。
function Test-GhAuthenticated {
    Invoke-Quiet { & gh auth status --hostname github.com --active 2>&1 | Out-Null }
    return ($LASTEXITCODE -eq 0)
}

# 拡張の最新リリースのタグを返す (取れなければ '')。認証済みの gh で引き、だめなら REST
# (lib/github.ps1 の Get-GitHubLatestReleaseTag。未認証の上限を他のツールと分け合う) に戻す。
function Get-GhExtensionLatestTag {
    param([Parameter(Mandatory)][string]$Repo)
    if (Test-Cmd 'gh') {
        $tag = Invoke-Quiet { & gh release view -R $Repo --json tagName -q .tagName 2>$null }
        if ($LASTEXITCODE -eq 0 -and $tag) { return ([string]@($tag)[0]).Trim() }
    }
    return Get-GitHubLatestReleaseTag -Repo $Repo
}

# 拡張の一覧 (owner/repo) を最新へそろえる。未導入なら入れる。
# `gh extension install --force` を使うのは、未導入なら入れ、導入済みなら最新へ上げる、を 1 つの
# コマンドで済ませられるため。`--pin` で入れた拡張も pin を外して最新へ上げる。`gh extension upgrade`
# (--force なし) は pin 付きを「pinned extensions can not be upgraded」で飛ばし、しかも終了コード 0 で返す。
# gh が未認証なら案内だけ出して飛ばす (doctor が古い版として映す)。
function Install-GhExtensions {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Repos)
    if ($Repos.Count -eq 0) { return }
    if (-not (Test-Cmd 'gh')) {
        Write-Fail 'gh が見つからないため gh の拡張をインストールできません'
        return
    }
    if (-not (Test-GhAuthenticated)) {
        Write-Warn "gh が未認証なので gh の拡張を飛ばしました ('gh auth login' の後に再実行)"
        return
    }
    $before = Get-GhExtensionList
    $installed = @()
    foreach ($repo in $Repos) {
        $out = Invoke-Quiet { & gh extension install --force $repo 2>&1 }
        if ($LASTEXITCODE -ne 0) {
            # 原因 (Windows 用の asset が無い、API の上限など) が分かるよう gh の最後の行を添える。
            $reason = (@($out) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Last 1)
            Write-Fail "$(Get-GhExtensionLabel $repo): gh extension install に失敗 (exit $LASTEXITCODE) $reason"
        } else {
            $installed += $repo
        }
    }
    if ($installed.Count -eq 0) { return }
    $after = Get-GhExtensionList
    foreach ($repo in $installed) {
        $label = Get-GhExtensionLabel $repo
        $old = Get-GhExtensionVersion -List $before -Repo $repo
        $new = Get-GhExtensionVersion -List $after -Repo $repo
        if (-not $new) {
            # `install --force` は名前で既存の拡張を探すので、同名の別の owner の拡張があるとそちらを上げて 0 で返す。
            Write-Fail "${label}: install は成功したが $repo が gh extension list に出ない (同名の別の拡張が入っていないか確認)"
        } elseif ($old -eq $new) {
            Write-Ok "${label}: $new (変更なし)"
        } else {
            Write-Ok "${label}: $(if ($old) { "$old → " })$new"
        }
    }
}

# doctor 用。拡張ごとに Show-ToolList へ渡せる項目 (@{ Label; Installed; Ver; Latest }) を返す。
# 利用側はツール一覧に連結して渡す (例: Show-ToolList (@($DoctorTools) + @(Get-GhExtensionDoctorTools $repos)))。
# 導入の判定は gh 本体の有無ではなく `gh extension list` に載っているかで行う (Installed)。
# 一覧は 1 回だけ取り、値を scriptblock へ埋め込む。GetNewClosure() を使わないのは、閉じた
# scriptblock が別のモジュールのスコープで動き、利用側が dot-source した lib の関数が見えなくなるため。
function Get-GhExtensionDoctorTools {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Repos)
    if ($Repos.Count -eq 0) { return @() }
    $quote = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $list = Get-GhExtensionList
    foreach ($repo in $Repos) {
        $cur = Get-GhExtensionVersion -List $list -Repo $repo
        @{
            Label     = Get-GhExtensionLabel $repo
            Installed = [bool]$cur
            Ver       = [scriptblock]::Create((& $quote $cur))
            Latest    = [scriptblock]::Create("Get-GhExtensionLatestTag -Repo $(& $quote $repo)")
        }
    }
}
