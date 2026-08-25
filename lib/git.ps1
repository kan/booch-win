#Requires -Version 5.1
#
# lib/git.ps1: 汎用機構 — 複数 git repo の一括 ff-only pull
#
# 消費側 (dotfiles-win) は「どの基準ディレクトリの・どの repo を・どのブランチで」だけを渡す。
# 対象は実在するものだけなので、そのマシンに clone していない repo 名が並んでいても害はない。
# 更新は ff-only に限り、許可ブランチ外・作業ツリーが汚れている repo には触らない (作業中の
# 変更を黙って巻き込まないため)。Linux 側 booch の lib/git.sh (booch_git_pull_repos /
# booch_git_pull_ff_clean) に対応する。
#
# 実 git を叩く箇所は seam (Get-BoochWinGitBranch / Test-BoochWinGitDirty /
# Get-BoochWinGitHead / Invoke-BoochWinGitFfPull) に切り出してあり、テストはそこを差し替える。

# 現在のブランチ名。detached HEAD なら 'HEAD'、取得できなければ空文字。
function Get-BoochWinGitBranch {
    param([Parameter(Mandatory)][string]$Path)
    $out = Invoke-Quiet { & git -C $Path rev-parse --abbrev-ref HEAD 2>$null }
    if ($LASTEXITCODE -ne 0) { return '' }
    return ([string]($out | Select-Object -First 1)).Trim()
}

# 作業ツリーに未コミットの変更 (untracked 含む) があるか。
function Test-BoochWinGitDirty {
    param([Parameter(Mandatory)][string]$Path)
    $out = Invoke-Quiet { & git -C $Path status --porcelain 2>$null }
    return [bool](@($out | Where-Object { $_ -and ([string]$_).Trim() }).Count)
}

# HEAD の commit sha。取得できなければ空文字。
function Get-BoochWinGitHead {
    param([Parameter(Mandatory)][string]$Path)
    $out = Invoke-Quiet { & git -C $Path rev-parse HEAD 2>$null }
    if ($LASTEXITCODE -ne 0) { return '' }
    return ([string]($out | Select-Object -First 1)).Trim()
}

# ff-only pull を実行し、成否と出力を返す (表示は呼び出し側の責務)。
function Invoke-BoochWinGitFfPull {
    param([Parameter(Mandatory)][string]$Path)
    $out = Invoke-Quiet { & git -C $Path pull --ff-only 2>&1 }
    return [pscustomobject]@{
        Success = ($LASTEXITCODE -eq 0)
        Output  = (@($out | ForEach-Object { [string]$_ }) -join "`n")
    }
}

# 1 repo を ff-only で更新し、結果コードを返す (1 行の状態表示もここで出す)。
# 返り値: notrepo / skip-branch / dirty / uptodate / updated / failed
#
# 「更新されたか」は pull 前後の HEAD sha を比べて判定する。git の "Already up to date" は
# locale で翻訳されるため、メッセージ照合だと日本語環境で崩れる (Linux 側は LC_ALL=C を
# 前置して回避しているが、sha 比較なら locale に依存しない)。
function Update-BoochWinGitRepo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Branches = @('master', 'main', 'develop'),
        [string]$Label = '',
        [int]$LabelWidth = 18
    )
    if (-not $Label) { $Label = Split-Path $Path -Leaf }
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return 'notrepo' }

    $branch = Get-BoochWinGitBranch -Path $Path
    if ($Branches -notcontains $branch) {
        $shown = if ($branch) { $branch } else { 'unknown' }
        Write-Status -Label $Label -Status 'skip' -Color Yellow -LabelWidth $LabelWidth `
            -Detail ('branch {0} (allowed: {1})' -f $shown, ($Branches -join ','))
        return 'skip-branch'
    }

    if (Test-BoochWinGitDirty -Path $Path) {
        Write-Status -Label $Label -Status 'skip' -Color Yellow -LabelWidth $LabelWidth `
            -Detail ('local changes ({0})' -f $branch)
        return 'dirty'
    }

    $before = Get-BoochWinGitHead -Path $Path
    $result = Invoke-BoochWinGitFfPull -Path $Path
    if (-not $result.Success) {
        $last = @($result.Output -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
        Write-Status -Label $Label -Status 'failed' -Color Red -LabelWidth $LabelWidth `
            -Detail ('{0}: {1}' -f $branch, $last)
        return 'failed'
    }

    $after = Get-BoochWinGitHead -Path $Path
    if ($before -and $after -and $before -ne $after) {
        Write-Status -Label $Label -Status 'updated' -Color Green -LabelWidth $LabelWidth -Detail $branch
        return 'updated'
    }
    Write-Status -Label $Label -Status 'up to date' -Color Green -LabelWidth $LabelWidth -Detail $branch
    return 'uptodate'
}

# 複数 repo をまとめて ff-only pull する。Repos は $BaseDir 配下のディレクトリ名か絶対パス。
# .git を持たないものは黙って除外する (clone していないマシンで警告を出さないため)。
function Invoke-BoochWinGitPullRepos {
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [string[]]$Repos = @(),
        [string[]]$Branches = @('master', 'main', 'develop')
    )
    if (-not (Test-Cmd 'git')) {
        Write-Info 'git 不在のため git pull をスキップ'
        return
    }

    $targets = @()
    foreach ($repo in (@($Repos) | Select-Object -Unique)) {
        if (-not $repo) { continue }
        $path = if ([System.IO.Path]::IsPathRooted($repo)) { $repo } else { Join-Path $BaseDir $repo }
        if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { continue }
        $targets += [pscustomobject]@{ Label = (Split-Path $path -Leaf); Path = $path }
    }

    if (-not $targets) {
        Write-Info '対象リポジトリが見つかりません'
        return
    }

    # ラベル幅は対象名の最長に合わせる (Write-Status の既定 28 は repo 名には広すぎる)。
    $width = (@($targets | ForEach-Object { $_.Label.Length }) | Measure-Object -Maximum).Maximum + 2
    foreach ($target in $targets) {
        Update-BoochWinGitRepo -Path $target.Path -Branches $Branches -Label $target.Label -LabelWidth $width | Out-Null
    }
}
