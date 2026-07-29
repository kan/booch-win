#Requires -Version 5.1
#
# lib/cleanup.ps1: 汎用機構 — 一時ファイル / ツールキャッシュ / WSL・Tauri の掃除、放置 git worktree の prune
#
# dotfiles-win.ps1 から dot-source される。消費側は Mode (light|full) と破壊的処理の
# opt-in フラグ (-CleanTauri / -CompactVhdx) を渡すだけ。vhdx の縮小は
# Invoke-BoochWinCompactWsl に切り出してあり、消費側は専用サブコマンド
# (dotfiles-win compact-wsl) からも直接呼べる。縮小そのものは Optimize-BoochWinVhdx
# (Hyper-V の Optimize-VHD か diskpart。wsl.exe に compact 相当は無い) で、管理者権限が要る。
# Tauri/WSL の実処理ヘルパーは lib/system.ps1
# (Clear-TauriTargets / Get-WslVhdxPath / Get-FileAllocatedSize / Test-IsElevated)。放置 worktree の prune は
# Invoke-BoochWinWorktreePrune (どの repo を対象にするかは消費側が渡す)。Linux 側 booch の
# lib/cleanup.sh (booch_cleanup_worktree_prune 含む) に対応。

# 掃除本体。表示は従来 dotfiles-win.ps1 の Invoke-Cleanup と同一 (タイトル行は消費側が出す)。
#   light: 7 日より古い一時ファイルのみ (引数なし setup からも回る軽量掃除)。
#   full : + npm/go キャッシュ。さらに opt-in で Tauri target 削除 / WSL vhdx 最適化。
function Invoke-BoochWinCleanup {
    param(
        [ValidateSet('light', 'full')][string]$Mode = 'full',
        [switch]$CleanTauri,
        [switch]$CompactVhdx
    )

    # --- 一時ファイル (7 日より古いものだけ。使用中ファイルはエラーを握って継続) ---
    Write-Host '--- temp files ---'
    $cutoff = (Get-Date).AddDays(-7)
    $freed = 0
    if ($env:TEMP -and (Test-Path $env:TEMP)) {
        foreach ($item in Get-ChildItem -Path $env:TEMP -Force -ErrorAction SilentlyContinue) {
            if ($item.LastWriteTime -ge $cutoff) { continue }
            try {
                $sz = if ($item.PSIsContainer) { 0 } else { [long]$item.Length }
                Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                $freed += $sz
            } catch {}
        }
    }
    Write-Ok ('古い一時ファイルを掃除 (~{0:N0} MB 解放)' -f ($freed / 1MB))

    # 以降は full 限定 (= 引数なし setup の light からは実行されない)。
    if ($Mode -eq 'full') {
        Write-Host ''
        Write-Host '--- tool caches ---'
        if (Test-Cmd 'npm') {
            Invoke-Quiet { & npm cache clean --force 2>&1 | Out-Null }
            Write-Ok 'npm cache cleaned'
        }
        if (Test-Cmd 'go') {
            Invoke-Quiet { & go clean -cache 2>&1 | Out-Null }
            Write-Ok 'go build cache cleaned'
        }

        # Tauri target クリアは破壊的なので、full かつ -CleanTauri 明示時のみ。
        if ($CleanTauri) {
            Write-Host ''
            Write-Host '--- Tauri targets (--clean-tauri) ---'
            Clear-TauriTargets
        }

        # vhdx 最適化も full かつ -CompactVhdx 明示時のみ (WSL を落とすため)。
        if ($CompactVhdx) {
            Write-Host ''
            Write-Host '--- WSL shutdown + disk optimize (--compact-vhdx) ---'
            Invoke-BoochWinCompactWsl
        }
    }

    Write-Host ''
    Write-Host 'Cleanup complete.'
}

# WSL 全体を停止して vhdx のロックを解放する。compact の前提であり、テストから実際に WSL を
# 落とさずに済むよう独立した関数にしてある (mock 対象)。
function Stop-BoochWinWsl {
    Write-Info 'wsl --shutdown ...'
    & wsl.exe --shutdown
    Start-Sleep -Seconds 2  # vhdx の解放を待つ
}

# WSL を停止して ext4.vhdx を縮小する (wsl --shutdown → 必要なら set-sparse → compact)。
# WSL 内でファイルを消しても vhdx は自動では縮まないため、Windows 側の空きを取り戻すには
# この操作が要る。WSL を落とすので破壊的: 消費側は専用サブコマンド (dotfiles-win compact-wsl)
# か cleanup の明示フラグ (--compact-vhdx) からだけ呼ぶ。稼働中のコンテナ・シェルは止まる。
# 見出し行は消費側が出す (cleanup の節 / サブコマンドのタイトル)。
function Invoke-BoochWinCompactWsl {
    if (-not (Test-Cmd 'wsl')) {
        Write-Warn 'wsl コマンドが見つかりません (WSL 未導入?)'
        return
    }
    Stop-BoochWinWsl

    $vhdxs = Get-WslVhdxPath
    if (-not $vhdxs) {
        Write-Warn 'WSL ディストロが見つかりません (スキップ)'
        return
    }
    Write-Info 'ヒント: 先に WSL 内で dotfiles cleanup (fstrim) を回すと最適化の効果が高まります'
    foreach ($v in $vhdxs) {
        # 見るのは論理サイズ (Length) ではなく実占有。sparse な vhdx では両者が大きく食い違い、
        # fstrim で解放した分は実占有にだけ現れる。
        $before = Get-FileAllocatedSize $v.Vhdx

        # スパース化が未設定の時だけ実施する (--allow-unsafe 必須)。
        # NTFS の SparseFile 属性で設定済みかを判定する。
        $isSparse = ((Get-Item $v.Vhdx).Attributes -band [System.IO.FileAttributes]::SparseFile) -ne 0
        if (-not $isSparse) {
            Write-Info ('set-sparse {0} ...' -f $v.Name)
            & wsl.exe --manage $v.Name --set-sparse true --allow-unsafe
            if ($LASTEXITCODE -ne 0) {
                Write-Fail ('{0}: set-sparse 失敗 (WSL が古い場合は wsl --update)' -f $v.Name)
            }
        } else {
            Write-Ok ('{0}: 既にスパース化済み (fstrim した分は自動で解放されます)' -f $v.Name)
        }

        Write-Info ('compacting {0} (実占有 {1:N1} GB)...' -f $v.Name, ($before / 1GB))
        if (Optimize-BoochWinVhdx -Path $v.Vhdx) {
            $after = Get-FileAllocatedSize $v.Vhdx
            Write-Ok ('{0}: 実占有 {1:N1} GB -> {2:N1} GB ({3:N1} GB 解放)' -f `
                $v.Name, ($before / 1GB), ($after / 1GB), (($before - $after) / 1GB))
        }
    }
}

# vhdx を縮小する。wsl.exe には compact 相当のオプションが無い (--manage が持つのは
# --move / --set-sparse / --set-default-user だけ) ので、Hyper-V の Optimize-VHD か
# diskpart の `compact vdisk` で行う。どちらも管理者権限が要り、対象 vhdx がデタッチ済み
# (= 事前に wsl --shutdown 済み) であることが前提。
# 戻り値: 縮小を実行できたら $true。
function Optimize-BoochWinVhdx {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-IsElevated)) {
        Write-Fail 'vhdx の縮小には管理者権限が必要です (管理者の PowerShell で実行してください)'
        return $false
    }

    # Hyper-V の PowerShell モジュールがあればそれを使う (diskpart より扱いが安全)。
    if (Get-Command 'Optimize-VHD' -ErrorAction SilentlyContinue) {
        try {
            Optimize-VHD -Path $Path -Mode Full -ErrorAction Stop
            return $true
        } catch {
            Write-Warn ('Optimize-VHD 失敗: {0} (diskpart で再試行します)' -f $_.Exception.Message)
        }
    }

    # フォールバック: diskpart。read-only でアタッチしてから compact する。
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        @(
            "select vdisk file=`"$Path`""
            'attach vdisk readonly'
            'compact vdisk'
            'detach vdisk'
            'exit'
        ) | Set-Content -LiteralPath $tmp -Encoding Ascii
        $out = & diskpart.exe /s $tmp 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Fail ('diskpart による縮小に失敗しました: {0}' -f (($out | Select-Object -Last 3) -join ' / '))
            return $false
        }
        return $true
    } catch {
        Write-Fail ('diskpart の実行に失敗しました: {0}' -f $_.Exception.Message)
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# 指定した各 git repo で `git worktree prune` を回す。実体が消えた worktree の登録メタだけを
# 掃除する (冪等・安全。実在する worktree は消さない)。git 不在・非 git ディレクトリはスキップ。
# 何の repo を対象にするかは消費側が決める (dotfiles-win.config.ps1 の $WorktreePruneRepos 等)。
# Linux 側 booch の booch_cleanup_worktree_prune と対称。
function Invoke-BoochWinWorktreePrune {
    param([string[]]$Repos = @())
    if (-not (Test-Cmd 'git')) {
        Write-Info 'git 不在のため worktree prune をスキップ'
        return
    }
    foreach ($repo in ($Repos | Select-Object -Unique)) {
        if (-not $repo -or -not (Test-Path (Join-Path $repo '.git'))) { continue }
        Write-Info "git worktree prune: $repo"
        Invoke-Quiet { & git -C $repo worktree prune -v 2>&1 | ForEach-Object { Write-Host "    $_" } }
    }
    Write-Ok 'git worktree のメタ掃除を実行しました'
}
