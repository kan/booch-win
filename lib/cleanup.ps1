#Requires -Version 5.1
#
# lib/cleanup.ps1: 汎用機構 — 一時ファイル / ツールキャッシュ / WSL・Tauri の掃除、放置 git worktree の prune
#
# dotfiles-win.ps1 から dot-source される。消費側は Mode (light|full) と破壊的処理の
# opt-in フラグ (-CleanTauri / -CompactVhdx) を渡すだけ。Tauri/WSL の実処理ヘルパーは
# lib/system.ps1 (Clear-TauriTargets / Get-WslVhdxPath)。放置 worktree の prune は
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
            if (Test-Cmd 'wsl') {
                Write-Info 'wsl --shutdown ...'
                & wsl.exe --shutdown
                Start-Sleep -Seconds 2  # vhdx の解放を待つ

                $vhdxs = Get-WslVhdxPath
                if (-not $vhdxs) {
                    Write-Warn 'WSL ディストロが見つかりません (スキップ)'
                } else {
                    Write-Info 'ヒント: 先に WSL 内で dotfiles cleanup (fstrim) を回すと最適化の効果が高まります'
                    foreach ($v in $vhdxs) {
                        $before = (Get-Item $v.Vhdx).Length

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
                            Write-Ok ('{0}: 既にスパース化済み' -f $v.Name)
                        }

                        # 実際の縮小は wsl --manage --compact で行う (管理者権限不要)。
                        Write-Info ('compacting {0} ({1:N0} MB)...' -f $v.Name, ($before / 1MB))
                        & wsl.exe --manage $v.Name --compact
                        if ($LASTEXITCODE -eq 0) {
                            $after = (Get-Item $v.Vhdx).Length
                            Write-Ok ('{0}: {1:N0} MB -> {2:N0} MB' -f $v.Name, ($before / 1MB), ($after / 1MB))
                        } else {
                            Write-Fail ('{0}: compact 失敗 (WSL が古い場合は wsl --update を試してください)' -f $v.Name)
                        }
                    }
                }
            } else {
                Write-Warn 'wsl コマンドが見つかりません (WSL 未導入?)'
            }
        }
    }

    Write-Host ''
    Write-Host 'Cleanup complete.'
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
