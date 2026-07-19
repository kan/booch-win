#requires -Version 5.1
# lib/wsl.ps1 を検証する (Pester 5)。wsl.exe を叩かずに、導入判定と状態の返り分けを確認する。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')
    . (Join-Path $lib 'wsl.ps1')

    # 実行時に存在しない可能性のある外部コマンドもモックできるよう関数スタブを置く。
    function wsl.exe { }
}

Describe 'Get-WslDistros' {
    It 'wsl.exe の UTF-16 出力 (null 挟み) から名前を取り出す' {
        # コンソールのエンコーディング次第で 1 文字ごとに null が入るケースを模す。
        Mock Invoke-Quiet { "U`0b`0u`0n`0t`0u`0-`02`06`0.`00`04`0`r`n" }
        Get-WslDistros | Should -Be @('Ubuntu-26.04')
    }

    It '空出力なら空配列' {
        Mock Invoke-Quiet { '' }
        (Get-WslDistros).Count | Should -Be 0
    }
}

Describe 'Install-WslDistro' {
    BeforeEach { Mock wsl.exe { } }

    It '導入済みなら already（何もしない）' {
        Mock Get-WslDistros { @('Ubuntu-26.04') }
        Install-WslDistro 'Ubuntu-26.04' | Should -Be 'already'
        Should -Invoke wsl.exe -Times 0
    }

    It '非管理者なら needs-admin（実行しない）' {
        Mock Get-WslDistros { @() }
        Mock Test-IsElevated { $false }
        Install-WslDistro 'Ubuntu-26.04' | Should -Be 'needs-admin'
        Should -Invoke wsl.exe -Times 0
    }

    It '導入後にディストロが現れれば installed' {
        Mock Test-IsElevated { $true }
        $script:seen = 0
        Mock Get-WslDistros { $script:seen++; if ($script:seen -eq 1) { @() } else { @('Ubuntu-26.04') } }
        Install-WslDistro 'Ubuntu-26.04' | Should -Be 'installed'
    }

    It '機能有効化だけで現れなければ needs-restart' {
        Mock Test-IsElevated { $true }
        Mock Get-WslDistros { @() }
        Install-WslDistro 'Ubuntu-26.04' | Should -Be 'needs-restart'
    }
}
