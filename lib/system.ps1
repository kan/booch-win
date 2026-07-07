#Requires -Version 5.1
#
# lib/system.ps1: 汎用機構 — タイムアウト/昇格/bin 配備/WSL・Tauri 掃除
#
# dotfiles-win.ps1 から dot-source される。詳細は kan/dotfiles#6。
# $Script:DisableTimeout / $Script:SetupWinDir 等はエントリ側で定義される。
# 注意: $PSCommandPath に依存する Get-DotfilesDir / Restart-Elevated は
# 「本体スクリプト自身のパス」を要するためエントリに残している。

# --no-timeout 指定時は 0 (= 無制限) を返す。各 WebRequest の -TimeoutSec に渡す。
function Get-EffectiveTimeout {
    param([int]$Default)
    if ($Script:DisableTimeout) { return 0 }
    return $Default
}

# 現在のプロセスが管理者権限で動いているか。
function Test-IsElevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# ~/.local/bin へ配備する dotfiles-win 関連スクリプト。配備 (Update-DotfilesWinBin) と
# doctor の鮮度チェック (Show-DotfilesWinBinStatus) で共有する単一の SSOT。
$Script:DotfilesWinBinFiles = @('dotfiles-win', 'dotfiles-win.ps1', 'dotfiles-win.cmd')

# ~/.local/bin に dotfiles-win 関連スクリプト 3 本を実体コピーで配置する。
# シンボリックリンクではなく実体コピーなので、リポジトリ側を git pull で
# 更新しただけでは bin 配下が古いままになる。本関数を pull 直後にも呼んで
# 入れ替える必要がある。
# 戻り値: $true なら 1 ファイル以上を更新／追加した
# 依存: Test-FilesEqual (lib/sync.ps1)。entry が全 lib をまとめて dot-source するため
# 実行時は常に解決される (単体読み込みする場合は sync.ps1 も先に source すること)。
function Update-DotfilesWinBin {
    $binDir = Join-Path $HOME '.local\bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $updated = $false
    foreach ($f in $Script:DotfilesWinBinFiles) {
        $src = Join-Path $Script:SetupWinDir $f
        $dst = Join-Path $binDir $f
        if (-not (Test-Path $src)) { continue }
        if ((-not (Test-Path $dst)) -or (-not (Test-FilesEqual $src $dst))) {
            Copy-Item $src $dst -Force
            Write-Ok "${f}: deployed to $binDir"
            $updated = $true
        } else {
            Write-Ok "${f}: up to date in $binDir"
        }
    }
    # 配備コピー (~/.local/bin) は自身のパスから repo を辿れないため、repo root を
    # marker に記録しておく。Get-DotfilesDir がここから lib/config の参照先を解決する
    # （clone 先が ~/dotfiles 以外でも、一度 repo 本体を実行すれば以降は追従する）。
    Set-Content -Path (Join-Path $binDir 'dotfiles-win.root') -Value $Script:DotfilesDir -Encoding UTF8
    return $updated
}

# ~/.local/bin の配備コピーが repo (setup-win/) と一致しているかを doctor 向けに表示する
# (Linux の symlink 配置診断 booch_doctor_symlinks に相当)。実体コピー方式は git pull 後に
# bin 配下だけ古くなる構造があるため、STALE を可視化する。情報表示のみで missing 集計には
# 影響しない (sync / setup を回せば Update-DotfilesWinBin が入れ替える)。
function Show-DotfilesWinBinStatus {
    param([int]$LabelWidth = 28)
    $binDir = Join-Path $HOME '.local\bin'
    foreach ($f in $Script:DotfilesWinBinFiles) {
        $src   = Join-Path $Script:SetupWinDir $f
        $dst   = Join-Path $binDir $f
        $label = "bin/$f"
        if (-not (Test-Path $src)) {
            Write-Status $label 'REPO MISSING' Red '' $LabelWidth
        } elseif (-not (Test-Path $dst)) {
            Write-Status $label 'NOT DEPLOYED' Yellow 'run dotfiles-win sync' $LabelWidth
        } elseif (Test-FilesEqual $src $dst) {
            Write-Status $label 'OK' Green '' $LabelWidth
        } else {
            Write-Status $label 'STALE' Yellow 'run dotfiles-win sync' $LabelWidth
        }
    }
}

# Git for Windows のインストールディレクトリ配下から起動しているプロセスを列挙する。
# Git.Git の winget upgrade (Inno Setup) は bash.exe 等が実行中だと、サイレント実行
# (/VERYSILENT /SUPPRESSMSGBOXES) の Retry/Cancel が自動 Cancel されて abort する。
# FromBash ガードは自プロセス由来の bash しか防げないため、別ウィンドウの git bash
# (Claude Code のセッション等) を upgrade 前にこれで検出してスキップ判断に使う。
function Get-GitForWindowsProcess {
    # git.exe の場所から install root を辿る (<root>\cmd\git.exe 等)。無ければ既定パス。
    $gitRoot = $null
    $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($gitCmd -and $gitCmd.Source) {
        $dir = Split-Path -Parent $gitCmd.Source
        while ($dir -and ((Split-Path -Leaf $dir) -match '^(cmd|bin|core|mingw64|usr)$')) {
            $dir = Split-Path -Parent $dir
        }
        $gitRoot = $dir
    }
    if (-not $gitRoot) { $gitRoot = 'C:\Program Files\Git' }
    if (-not (Test-Path $gitRoot)) { return @() }

    # 実行ファイルパスが install root 配下のプロセスを列挙する (WSL の
    # C:\Windows\System32\bash.exe 等は除外される)。アクセスできないプロセスの
    # Path は $null になるだけなので追加のエラー処理は不要。
    $prefix = $gitRoot.TrimEnd('\') + '\'
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
}

# 現在のプロセスの祖先 PID を列挙する (自プロセスは含まない)。
# Git for Windows 更新前の bash 終了で「自分の祖先を殺して自爆」しないための
# 判定に使う (FromBash ラッパーを介さず git bash 内で powershell を開いた
# ケースは環境変数では検出できないため、プロセス系譜で見る)。
function Get-CurrentProcessAncestorId {
    $ids = @()
    $currentId = $PID
    # 親を順にたどる。PID 再利用で系譜が循環する可能性に備えて上限を置く。
    for ($i = 0; $i -lt 32; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$currentId" -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.ParentProcessId) { break }
        $currentId = $p.ParentProcessId
        $ids += $currentId
    }
    return $ids
}

# 登録済み WSL ディストリビューションの ext4.vhdx パスを列挙する。
function Get-WslVhdxPath {
    $lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $result = @()
    if (-not (Test-Path $lxssRoot)) { return $result }
    foreach ($key in Get-ChildItem $lxssRoot -ErrorAction SilentlyContinue) {
        $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        if ($props -and $props.BasePath) {
            $base = $props.BasePath -replace '^\\\\\?\\', ''
            $vhdx = Join-Path $base 'ext4.vhdx'
            if (Test-Path $vhdx) {
                $result += [pscustomobject]@{
                    Name = $props.DistributionName
                    Vhdx = $vhdx
                }
            }
        }
    }
    return $result
}

# Tauri/Rust プロジェクトの src-tauri/target (Rust ビルド成果物、数 GB に
# なりがち) を掃除する。Windows ユーザーディレクトリ (C:\Users\<user>) 直下の
# 各フォルダ配下を探索する。AppData 等の隠し/システムフォルダは -Force を
# 付けないことで除外される。誤削除を避けるため src-tauri マーカーを持つ
# ディレクトリに限定し、cargo があれば cargo clean、無ければディレクトリ削除で
# フォールバックする。
function Clear-TauriTargets {
    if (-not (Test-Path $HOME)) {
        Write-Warn "ユーザーディレクトリが見つかりません: $HOME"
        return
    }

    $found = 0
    $freed = 0
    # $HOME 直下フォルダ配下を深さ 4 まで探索 (隠しフォルダは -Force 無しで除外)
    $tauriDirs = Get-ChildItem -Path $HOME -Directory -Recurse -Depth 4 -Filter 'src-tauri' -ErrorAction SilentlyContinue
    foreach ($d in $tauriDirs) {
        $target = Join-Path $d.FullName 'target'
        if (-not (Test-Path $target)) { continue }

        $sz = (Get-ChildItem -Path $target -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if (-not $sz) { $sz = 0 }
        $proj = Split-Path -Parent $d.FullName
        Write-Info ('cleaning {0} ({1:N0} MB)...' -f $proj, ($sz / 1MB))

        $manifest = Join-Path $d.FullName 'Cargo.toml'
        $ok = $false
        if ((Test-Cmd 'cargo') -and (Test-Path $manifest)) {
            Invoke-Quiet { & cargo clean --manifest-path $manifest 2>&1 | Out-Null }
            $ok = (-not (Test-Path $target))
        }
        if (-not $ok) {
            try { Remove-Item $target -Recurse -Force -ErrorAction Stop; $ok = $true } catch {}
        }
        if ($ok) {
            Write-Ok ('{0}: {1:N0} MB 解放' -f (Split-Path -Leaf $proj), ($sz / 1MB))
            $found++
            $freed += $sz
        } else {
            Write-Fail ('{0}: target 削除失敗' -f (Split-Path -Leaf $proj))
        }
    }

    if ($found -eq 0) {
        Write-Ok 'クリア対象の Tauri target はありませんでした'
    } else {
        Write-Ok ('Tauri target を {0} 件クリア (~{1:N0} MB 解放)' -f $found, ($freed / 1MB))
    }
}
