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

# WSL の ext4.vhdx の実占有を減らす。取れる手段は vhdx が sparse かどうかで排他的に決まる:
#
#   sparse   → ゲストの TRIM (WSL 内の fstrim) で実占有が自動的に減る。VHD API の制限で
#              compact は**適用できない** ("must not be sparse")。よって WSL を落とす必要も
#              無いので、状態を報告して何もしない
#   非 sparse → 自動では減らないので、WSL を停止 (vhdx をデタッチ) して compact する
#
# つまり「WSL を落とす」のは非 sparse の vhdx があるときだけ。無条件に落として失敗するのは
# 稼働中のコンテナ・シェルを無駄に殺すだけなので、判定を先に行う。
# 見出し行は消費側が出す (cleanup の節 / サブコマンドのタイトル)。
function Invoke-BoochWinCompactWsl {
    if (-not (Test-Cmd 'wsl')) {
        Write-Warn 'wsl コマンドが見つかりません (WSL 未導入?)'
        return
    }

    $vhdxs = Get-WslVhdxPath
    if (-not $vhdxs) {
        Write-Warn 'WSL ディストロが見つかりません (スキップ)'
        return
    }

    foreach ($v in $vhdxs) {
        Write-Info ('{0}: 実占有 {1:N1} GB (論理 {2:N1} GB)' -f `
            $v.Name, ((Get-FileAllocatedSize $v.Vhdx) / 1GB), ((Get-Item $v.Vhdx).Length / 1GB))
    }

    # compact が要る (= 非 sparse) のはどれか。
    $targets = @($vhdxs | Where-Object { -not (Test-FileSparse $_.Vhdx) })
    if ($targets.Count -eq 0) {
        Write-Ok 'すべて sparse です。解放は WSL 内の fstrim で自動的に行われます'
        Write-Info "回収するには WSL 内で 'dotfiles cleanup' (fstrim を含む) を回してください"
        Write-Info 'sparse な vhdx に compact は適用できません (VHD API の制限)。WSL を停止せず終了します'
        return
    }

    # 縮小には管理者権限が要る (Optimize-VHD / diskpart のどちらも)。権限が無いまま進むと
    # WSL を停止した末に必ず失敗する — sparse 判定と同じ理由で、停止の前に弾く。消費側
    # (compact-wsl 相当のサブコマンド) が昇格の面倒を見ることもあるが、cleanup の
    # -CompactVhdx のようにここへ直接来る経路もあるため、機構側でも止める。
    if (-not (Test-IsElevated)) {
        Write-Fail 'vhdx の縮小には管理者権限が必要です (管理者の PowerShell で実行してください)'
        Write-Info 'WSL は停止していません'
        return
    }

    Stop-BoochWinWsl
    foreach ($v in $targets) {
        $before = Get-FileAllocatedSize $v.Vhdx
        Write-Info ('compacting {0} (実占有 {1:N1} GB)...' -f $v.Name, ($before / 1GB))
        if (Optimize-BoochWinVhdx -Path $v.Vhdx) {
            $after = Get-FileAllocatedSize $v.Vhdx
            Write-Ok ('{0}: 実占有 {1:N1} GB -> {2:N1} GB ({3:N1} GB 解放)' -f `
                $v.Name, ($before / 1GB), ($after / 1GB), (($before - $after) / 1GB))
            Write-Info ("以後の自動解放には sparse 化が有効です: wsl --manage {0} --set-sparse true --allow-unsafe" -f $v.Name)
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

    # sparse なファイルは VHD API が開けない ("Virtual hard disk files must be uncompressed
    # and unencrypted and must not be sparse")。昇格しても結果は変わらないので、権限確認より
    # 先に弾く (無駄な UAC プロンプトを出さない)。sparse の場合は fstrim 側で解放される。
    if (Test-FileSparse -Path $Path) {
        Write-Warn 'sparse な vhdx は compact できません (VHD API の制限)。解放は WSL 内の fstrim で行われます'
        return $false
    }

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
    # diskpart はパスをスクリプトファイルへ文字列として埋め込む形になるので、ここだけは
    # 改行・引用符を含むパスを弾く (昇格した diskpart.exe に追加コマンドを読ませないため)。
    # Optimize-VHD 経路は引数渡しなのでこの心配は無い。
    if ($Path -match '[\r\n"]') {
        Write-Fail 'vhdx のパスに使用できない文字 (改行 / 引用符) が含まれています'
        return $false
    }

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
            # diskpart はスクリプト中の 1 行が失敗するとそれ以降を実行しない。attach まで通って
            # compact で失敗した場合、detach vdisk に到達せず read-only アタッチのまま残り、
            # 次の WSL 起動が「ファイル使用中」で失敗しうる。後始末を試みる。
            Dismount-BoochWinVhdx -Path $Path
            return $false
        }
        return $true
    } catch {
        Write-Fail ('diskpart の実行に失敗しました: {0}' -f $_.Exception.Message)
        Dismount-BoochWinVhdx -Path $Path
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# diskpart でアタッチしたまま残った vhdx をデタッチする (compact 失敗時の後始末)。
# best-effort — 元々アタッチされていなければ diskpart がエラーを返すだけで害はないので、
# 失敗は握って呼び出し側の主エラーを覆い隠さない。
function Dismount-BoochWinVhdx {
    param([Parameter(Mandatory)][string]$Path)

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        @(
            "select vdisk file=`"$Path`""
            'detach vdisk'
            'exit'
        ) | Set-Content -LiteralPath $tmp -Encoding Ascii
        & diskpart.exe /s $tmp 2>&1 | Out-Null
    } catch {
        # 後始末の失敗は主エラー (呼び出し側が既に出している) を覆い隠さないよう握る。
        Write-Debug ('vhdx のデタッチに失敗: {0}' -f $_.Exception.Message)
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
