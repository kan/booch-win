#requires -Version 5.1
# lib/store.ps1 を検証する (Pester 5)。レジストリには触れず、読み書きの cmdlet をモックする。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')
    . (Join-Path $lib 'store.ps1')
}

Describe 'Get-StoreAutoDownloadPolicy / Test-StoreAutoUpdateDisabled' {
    It 'AutoDownload = 2 なら止まっている' {
        Mock Get-ItemProperty { [pscustomobject]@{ AutoDownload = 2 } }
        Get-StoreAutoDownloadPolicy | Should -Be 2
        Test-StoreAutoUpdateDisabled | Should -BeTrue
    }

    It 'AutoDownload = 4 なら止まっていない' {
        Mock Get-ItemProperty { [pscustomobject]@{ AutoDownload = 4 } }
        Test-StoreAutoUpdateDisabled | Should -BeFalse
    }

    It '未設定なら $null で、止まっていない' {
        Mock Get-ItemProperty { }
        Get-StoreAutoDownloadPolicy | Should -BeNullOrEmpty
        Test-StoreAutoUpdateDisabled | Should -BeFalse
    }
}

Describe 'Disable-StoreAutoUpdate' {
    BeforeEach {
        Mock Test-StoreAutoUpdateDisabled { $false }
        Mock Test-IsElevated { $true }
        Mock Test-Path { $true }
        Mock New-Item { }
        Mock Set-ItemProperty { }
    }

    It '止まっていれば already (何も書かない)' {
        Mock Test-StoreAutoUpdateDisabled { $true }
        Disable-StoreAutoUpdate | Should -Be 'already'
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }

    It '非管理者なら needs-admin (何も書かない)' {
        Mock Test-IsElevated { $false }
        Disable-StoreAutoUpdate | Should -Be 'needs-admin'
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }

    It 'キーがあれば作り直さず AutoDownload = 2 を書く' {
        Disable-StoreAutoUpdate | Should -Be 'disabled'
        Should -Invoke New-Item -Times 0 -Exactly
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'AutoDownload' -and $Value -eq 2 -and $Type -eq 'DWord'
        }
    }

    It 'キーが無ければ作ってから書く' {
        Mock Test-Path { $false }
        Disable-StoreAutoUpdate | Should -Be 'disabled'
        Should -Invoke New-Item -Times 1 -Exactly
        Should -Invoke Set-ItemProperty -Times 1 -Exactly
    }

    It '書き込みに失敗したら throw する' {
        Mock Set-ItemProperty { throw 'access denied' }
        { Disable-StoreAutoUpdate } | Should -Throw '*access denied*'
    }
}
