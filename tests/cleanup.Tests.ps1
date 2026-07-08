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

    It '不正な Mode は ValidateSet で弾く' {
        { Invoke-BoochWinCleanup -Mode 'bogus' } | Should -Throw
    }
}
