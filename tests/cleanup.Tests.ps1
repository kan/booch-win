#requires -Version 5.1
# lib/cleanup.ps1 の Invoke-BoochWinCleanup を検証する (Pester 5)。
# $env:TEMP を使い捨てディレクトリへ差し替え、light/full と opt-in フラグの分岐を見る。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')    # Clear-TauriTargets / Get-WslVhdxPath (mock 対象)
    . (Join-Path $lib 'cleanup.ps1')
    $script:OrigTemp = $env:TEMP
}

AfterAll { $env:TEMP = $script:OrigTemp }

Describe 'Invoke-BoochWinCleanup' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}; Mock Write-Fail {}
        $script:Tmp = Join-Path $TestDrive ('t_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
        $env:TEMP = $script:Tmp
    }
    AfterEach { $env:TEMP = $script:OrigTemp }

    It '7 日より古い一時ファイルを削除し、新しいものは残す' {
        $old = Join-Path $script:Tmp 'old.txt'; Set-Content -LiteralPath $old -Value 'x'
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-10)
        $new = Join-Path $script:Tmp 'new.txt'; Set-Content -LiteralPath $new -Value 'y'
        Invoke-BoochWinCleanup -Mode light
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $new | Should -BeTrue
    }

    It 'light では tool caches 節を実行しない (Test-Cmd を呼ばない)' {
        Mock Test-Cmd { $false }
        Invoke-BoochWinCleanup -Mode light
        Should -Invoke Test-Cmd -Times 0
    }

    It 'full + -CleanTauri で Clear-TauriTargets を呼ぶ' {
        Mock Test-Cmd { $false }        # npm/go/wsl は skip
        Mock Clear-TauriTargets {}
        Invoke-BoochWinCleanup -Mode full -CleanTauri
        Should -Invoke Clear-TauriTargets -Times 1
    }

    It 'full でも -CleanTauri なしなら Clear-TauriTargets を呼ばない' {
        Mock Test-Cmd { $false }
        Mock Clear-TauriTargets {}
        Invoke-BoochWinCleanup -Mode full
        Should -Invoke Clear-TauriTargets -Times 0
    }

    It 'full + -CompactVhdx で wsl 不在なら warn して落ちない' {
        Mock Test-Cmd { $false }
        Mock Clear-TauriTargets {}
        { Invoke-BoochWinCleanup -Mode full -CompactVhdx } | Should -Not -Throw
    }

    It 'full + -CompactVhdx は compact 処理へ委譲する' {
        Mock Test-Cmd { $false }
        Mock Invoke-BoochWinCompactWsl {}
        Invoke-BoochWinCleanup -Mode full -CompactVhdx
        Should -Invoke Invoke-BoochWinCompactWsl -Times 1
    }

    It 'full でも -CompactVhdx なしなら compact しない (WSL を落とさない)' {
        Mock Test-Cmd { $false }
        Mock Invoke-BoochWinCompactWsl {}
        Invoke-BoochWinCleanup -Mode full
        Should -Invoke Invoke-BoochWinCompactWsl -Times 0
    }

    It '不正な Mode は ValidateSet で弾く' {
        { Invoke-BoochWinCleanup -Mode 'bogus' } | Should -Throw
    }
}

Describe 'Invoke-BoochWinCompactWsl' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}; Mock Write-Fail {}
    }

    It 'wsl 不在なら warn して落ちない (WSL 未導入の Windows)' {
        Mock Test-Cmd { $false }
        Mock Get-WslVhdxPath { @() }
        { Invoke-BoochWinCompactWsl } | Should -Not -Throw
        Should -Invoke Write-Warn -Times 1
    }

    It 'ディストロが見つからなければ停止せず抜ける' {
        Mock Test-Cmd { $true }
        Mock Stop-BoochWinWsl {}    # 実際に WSL を落とさない
        Mock Get-WslVhdxPath { @() }
        { Invoke-BoochWinCompactWsl } | Should -Not -Throw
        Should -Invoke Stop-BoochWinWsl -Times 0
        Should -Invoke Write-Warn -Times 1
    }

    It 'wsl 不在なら停止も試みない' {
        Mock Test-Cmd { $false }
        Mock Stop-BoochWinWsl {}
        Invoke-BoochWinCompactWsl
        Should -Invoke Stop-BoochWinWsl -Times 0
    }

    # sparse な vhdx は compact できない (VHD API の制限)。落としても失敗するだけなので、
    # WSL を止めずに状態だけ報告する ← 実際に稼働中コンテナを無駄に殺した回帰のガード。
    It 'すべて sparse なら WSL を止めず compact も試みない' {
        $f = Join-Path $TestDrive 'sparse.vhdx'
        Set-Content -LiteralPath $f -Value 'x'
        Mock Test-Cmd { $true }
        Mock Stop-BoochWinWsl {}
        Mock Get-WslVhdxPath { @([pscustomobject]@{ Name = 'Ubuntu'; Vhdx = $f }) }
        Mock Test-FileSparse { $true }
        Mock Optimize-BoochWinVhdx { $true }
        Mock Get-FileAllocatedSize { 100GB }
        Invoke-BoochWinCompactWsl
        Should -Invoke Stop-BoochWinWsl -Times 0
        Should -Invoke Optimize-BoochWinVhdx -Times 0
    }

    It '非 sparse の vhdx は停止して Optimize-BoochWinVhdx へ渡し、前後を報告する' {
        $f = Join-Path $TestDrive 'plain.vhdx'
        Set-Content -LiteralPath $f -Value 'x'
        Mock Test-Cmd { $true }
        Mock Stop-BoochWinWsl {}
        Mock Get-WslVhdxPath { @([pscustomobject]@{ Name = 'Ubuntu'; Vhdx = $f }) }
        Mock Test-FileSparse { $false }
        Mock Optimize-BoochWinVhdx { $true }
        # 実占有は縮小の前後で変わる想定 (報告用の 1 回目 → compact 前 → compact 後)。
        $script:calls = 0
        Mock Get-FileAllocatedSize { $script:calls++; if ($script:calls -le 2) { 100GB } else { 60GB } }
        Invoke-BoochWinCompactWsl
        Should -Invoke Stop-BoochWinWsl -Times 1
        Should -Invoke Optimize-BoochWinVhdx -Times 1
        Should -Invoke Write-Ok -ParameterFilter { $Msg -match '40\.0 GB 解放' } -Times 1
    }
}

Describe 'Optimize-BoochWinVhdx' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}; Mock Write-Fail {}
    }

    # sparse は VHD API が開けない。昇格しても結果は変わらないので、権限確認より先に弾く
    # (無駄な UAC プロンプトを出さないため)。
    It 'sparse なら昇格を確認する前に false を返す' {
        Mock Test-FileSparse { $true }
        Mock Test-IsElevated { $true }
        Optimize-BoochWinVhdx -Path 'X:\dummy.vhdx' | Should -BeFalse
        Should -Invoke Test-IsElevated -Times 0
        Should -Invoke Write-Warn -Times 1
    }

    # 非 sparse でも Optimize-VHD / diskpart はどちらも昇格が要る。
    It '非 sparse かつ非昇格なら実行せず false を返す' {
        Mock Test-FileSparse { $false }
        Mock Test-IsElevated { $false }
        Optimize-BoochWinVhdx -Path 'X:\dummy.vhdx' | Should -BeFalse
        Should -Invoke Write-Fail -Times 1
    }
}

Describe 'Invoke-BoochWinWorktreePrune' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}
    }

    It '実体が消えた worktree の登録メタだけを prune する' {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git が無い環境'
            return
        }
        $repo = Join-Path $TestDrive ('r_' + [guid]::NewGuid().ToString('N'))
        $wt   = Join-Path $TestDrive ('w_' + [guid]::NewGuid().ToString('N'))
        git init -q $repo
        git -C $repo -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
        git -C $repo worktree add -q $wt 2>$null
        Remove-Item -Recurse -Force $wt          # 実体を消す (登録メタは残り prunable)
        (@(git -C $repo worktree list)).Count | Should -Be 2
        Invoke-BoochWinWorktreePrune -Repos @($repo)
        (@(git -C $repo worktree list)).Count | Should -Be 1
    }

    It 'git 不在ならスキップして落ちない' {
        Mock Test-Cmd { $false }
        { Invoke-BoochWinWorktreePrune -Repos @('x') } | Should -Not -Throw
    }

    It '非 git ディレクトリはスキップして落ちない' {
        Mock Test-Cmd { $true }
        $d = Join-Path $TestDrive ('n_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        { Invoke-BoochWinWorktreePrune -Repos @($d) } | Should -Not -Throw
    }
}
