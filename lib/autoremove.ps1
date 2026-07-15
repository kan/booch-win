#Requires -Version 5.1
#
# lib/autoremove.ps1: 汎用機構 — 宣言から外れた Claude プラグイン / marketplace / codex skill の掃除
#
# dotfiles-win.ps1 から dot-source される。何を残すか (KeepPlugins / KeepMarketplaces /
# KeepCodexSkills) は個人選択なので、消費側 (dotfiles-win.config.ps1 の $ClaudePlugins /
# $ClaudeMarketplaces / $CodexSkillsFromMarketplace) から渡す。ここは「やり方」だけを持つ。
# Linux 側 dotfiles の dotfiles_claude_autoremove_plan / _apply_one に対応する。
#
# 対象と検出基準 (いずれも「宣言に無い＝リスト外」だけを候補にする):
#   - plugin      : `claude plugin list` の導入済みのうち KeepPlugins (ShortName) に無いもの。
#   - marketplace : `claude plugin marketplace list` の登録済みのうち KeepMarketplaces に無いもの
#                   (remove は clone ディレクトリも消す)。
#   - mktclone    : ~/.claude/plugins/marketplaces/ 配下で「未登録かつ KeepMarketplaces 外」の
#                   clone 残渣 (登録済みは marketplace 側で処理するので二重計上しない)。
#   - codexskill  : ~/.codex/skills/ 配下で KeepCodexSkills (配備名) に無いもの。実体コピーのため
#                   ユーザーが手で置いたスキルを巻き込みうる。確認プロンプトで必ず一覧提示する。
#
# 対象外 (Linux と非対称なので扱わない):
#   - MCP サーバー : Windows は MCP を登録しないため宣言が空で、全件を「宣言外」と誤検出する。
#   - $SyncPairs   : symlink でなく実体コピーで、dotfiles 由来かユーザー own のファイルか判別する
#                    マーカーが無い (安全に残骸検出できない)。
#
# claude 不在時は plugin / marketplace / mktclone を判定不能としてスキップし、ファイルシステムで
# 判定できる codexskill だけ続行する。

# `claude plugin list` の導入済みプラグイン ShortName を配列で返す (claude 不在なら空)。
# 出力の各ブロック先頭 `❯ name@marketplace` から name を拾う (Show-ClaudePlugins と同じ規約)。
function Get-BoochWinInstalledPlugin {
    if (-not (Test-Cmd 'claude')) { return @() }
    $out = Get-ClaudePluginList
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '^\s*❯\s+(\S+)') {
            $names.Add(($Matches[1] -split '@')[0])
        }
    }
    return $names.ToArray()
}

# `claude plugin marketplace list` の登録済み marketplace 名を配列で返す (claude 不在なら空)。
function Get-BoochWinRegisteredMarketplace {
    if (-not (Test-Cmd 'claude')) { return @() }
    $out = Invoke-Quiet { & claude plugin marketplace list 2>&1 | Out-String }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '^\s*❯\s+(\S+)') {
            $names.Add(($Matches[1] -split '@')[0])
        }
    }
    return $names.ToArray()
}

# 宣言から外れた名残の「削除候補」を算出して配列で返す (実削除はしない)。1 要素 =
# [pscustomobject]@{ Kind; Id; Target; Desc }。Kind: plugin / marketplace / mktclone / codexskill。
# Target は適用時に使う実体 (plugin/marketplace は CLI 名、mktclone/codexskill は絶対パス)。
# 適用順の依存 (プラグインを marketplace remove より先に消す) に合わせ、この順で並べて返す。
# Root は既定を上書きできる (テスト用シーム)。
function Get-BoochWinAutoremovePlan {
    param(
        [string[]]$KeepPlugins = @(),
        [string[]]$KeepMarketplaces = @(),
        [string[]]$KeepCodexSkills = @(),
        [string]$MarketplacesRoot = (Join-Path $HOME '.claude\plugins\marketplaces'),
        [string]$CodexSkillsRoot  = (Join-Path $HOME '.codex\skills')
    )
    $plan = New-Object System.Collections.Generic.List[object]

    if (Test-Cmd 'claude') {
        # plugin: 導入済みのうち KeepPlugins に無いもの。
        foreach ($name in (Get-BoochWinInstalledPlugin)) {
            if ($KeepPlugins -contains $name) { continue }
            $plan.Add([pscustomobject]@{ Kind = 'plugin'; Id = $name; Target = $name; Desc = 'リスト外プラグイン' })
        }

        # marketplace: 登録済みのうち KeepMarketplaces に無いもの。mktclone の二重計上を
        # 避けるため登録済み名は控えておく。
        $registered = @(Get-BoochWinRegisteredMarketplace)
        foreach ($name in $registered) {
            if ($KeepMarketplaces -contains $name) { continue }
            $plan.Add([pscustomobject]@{ Kind = 'marketplace'; Id = $name; Target = $name; Desc = 'リスト外 marketplace' })
        }

        # mktclone: marketplaces/ 配下に残るが未登録かつ KeepMarketplaces 外の clone 残渣。
        # ドット始まり (.git 等) はツール内部の隠しディレクトリなので対象外 (Linux の
        # glob `*/` がドットを拾わないのと同じ)。
        if (Test-Path -LiteralPath $MarketplacesRoot) {
            foreach ($d in (Get-ChildItem -LiteralPath $MarketplacesRoot -Directory -ErrorAction SilentlyContinue)) {
                if ($d.Name -like '.*') { continue }
                if ($KeepMarketplaces -contains $d.Name) { continue }
                if ($registered -contains $d.Name) { continue }
                $plan.Add([pscustomobject]@{ Kind = 'mktclone'; Id = $d.Name; Target = $d.FullName; Desc = '未登録 marketplace clone 残渣' })
            }
        }
    }

    # codexskill: ~/.codex/skills/ 配下で KeepCodexSkills に無いもの。実体コピーなので手動配置の
    # スキルを巻き込みうる旨を Desc に残す (確認プロンプトで一覧提示される)。claude の有無に依らず判定。
    # ドット始まり (.system 等 codex 内部ディレクトリ) は配備スキルではないので対象外。
    if (Test-Path -LiteralPath $CodexSkillsRoot) {
        foreach ($d in (Get-ChildItem -LiteralPath $CodexSkillsRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -like '.*') { continue }
            if ($KeepCodexSkills -contains $d.Name) { continue }
            $plan.Add([pscustomobject]@{ Kind = 'codexskill'; Id = $d.Name; Target = $d.FullName; Desc = 'リスト外 codex skill (手動配置の可能性あり)' })
        }
    }

    return $plan.ToArray()
}

# $Path が $Root 配下の実ディレクトリのときだけ削除する (誤ったパスの再帰削除を防ぐ安全弁)。
# 成功で $true、範囲外 / 不在 / 失敗で $false。mktclone / codexskill の適用で使う。
function Remove-BoochWinDirUnder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    try {
        $full     = [System.IO.Path]::GetFullPath($Path)
        $rootFull = [System.IO.Path]::GetFullPath($Root)
    } catch {
        return $false
    }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if (-not $rootFull.EndsWith($sep)) { $rootFull += $sep }
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# 算出済みの plan 要素 1 件を実際に削除する。Get-BoochWinAutoremovePlan と同じ Root 既定を持つ
# (mktclone/codexskill の安全弁再検証に使う)。成功で $true。呼び出し側 (Invoke-BoochWinAutoremove)
# が確認後にのみ呼ぶ。
function Invoke-BoochWinAutoremoveOne {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Target,
        [string]$MarketplacesRoot = (Join-Path $HOME '.claude\plugins\marketplaces'),
        [string]$CodexSkillsRoot  = (Join-Path $HOME '.codex\skills')
    )
    switch ($Kind) {
        'plugin' {
            if (-not (Test-Cmd 'claude')) { return $false }
            Invoke-Quiet { & claude plugin uninstall $Target 2>&1 | Out-Null }
            return ($LASTEXITCODE -eq 0)
        }
        'marketplace' {
            if (-not (Test-Cmd 'claude')) { return $false }
            Invoke-Quiet { & claude plugin marketplace remove $Target 2>&1 | Out-Null }
            return ($LASTEXITCODE -eq 0)
        }
        'mktclone'   { return (Remove-BoochWinDirUnder -Path $Target -Root $MarketplacesRoot) }
        'codexskill' { return (Remove-BoochWinDirUnder -Path $Target -Root $CodexSkillsRoot) }
        default      { return $false }
    }
}

# autoremove のオーケストレーション。plan を算出し、一覧提示 → (dry-run/確認) → 実削除まで行う。
# 表示・確認の作法は Invoke-BoochWinCleanup / Invoke-BoochWinSync に揃える。消費側 (dotfiles-win)
# は Keep 一覧 (config 由来) と -DryRun / -AssumeYes を渡すだけの薄いラッパーになる。
function Invoke-BoochWinAutoremove {
    param(
        [string[]]$KeepPlugins = @(),
        [string[]]$KeepMarketplaces = @(),
        [string[]]$KeepCodexSkills = @(),
        [switch]$DryRun,
        [switch]$AssumeYes
    )
    Write-Host '=== dotfiles-win autoremove ==='
    Write-Host ''

    $plan = @(Get-BoochWinAutoremovePlan -KeepPlugins $KeepPlugins `
            -KeepMarketplaces $KeepMarketplaces -KeepCodexSkills $KeepCodexSkills)

    if ($plan.Count -eq 0) {
        Write-Ok '削除候補はありません (宣言と実体は一致)。'
        return
    }

    Write-Host '宣言 ($ClaudePlugins / $ClaudeMarketplaces / $CodexSkillsFromMarketplace) から'
    Write-Host '外れた次の名残が見つかりました:'
    Write-Host ''
    foreach ($e in $plan) {
        Write-Host ('  [{0}] {1}' -f $e.Kind.PadRight(11), $e.Id)
        if ($e.Desc) { Write-Host ('  {0}  {1}' -f (' ' * 13), $e.Desc) }
    }
    Write-Host ''

    if ($DryRun) {
        Write-Info '(--dry-run のため削除しません)'
        return
    }

    if (-not $AssumeYes) {
        $ans = Read-Host ('上記 {0} 件を削除しますか? [y/N]' -f $plan.Count)
        if ($ans -notmatch '^[Yy]') {
            Write-Info '中止しました。'
            return
        }
    }

    foreach ($e in $plan) {
        if (Invoke-BoochWinAutoremoveOne -Kind $e.Kind -Target $e.Target) {
            Write-Ok ('removed: [{0}] {1}' -f $e.Kind, $e.Id)
        } else {
            Write-Fail ('failed : [{0}] {1}' -f $e.Kind, $e.Id)
        }
    }
}
