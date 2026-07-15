#requires -Version 5.1
# lib/autoremove.ps1 を検証する (Pester 5)。claude 出力の解釈と plan 算出・安全弁・
# オーケストレーションの分岐を、外部 exe を叩かずにシーム関数の Mock と TestDrive で見る。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'claude.ps1')      # Get-ClaudePluginList (mock 対象)
    . (Join-Path $lib 'autoremove.ps1')
}

Describe 'Get-BoochWinAutoremovePlan' {
    # 注: Test-Cmd の mock は各 It で明示する。BeforeEach の既定を It で上書きすると
    # parameter filter 付き mock の優先順位が紛らわしくなるため (実 claude を誤って叩く)。
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}; Mock Write-Fail {}
        $script:MkRoot = Join-Path $TestDrive ('mk_' + [guid]::NewGuid().ToString('N'))
        $script:CxRoot = Join-Path $TestDrive ('cx_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:MkRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $script:CxRoot -Force | Out-Null
    }

    It 'KeepPlugins に無い導入済みプラグインだけを plugin 候補にする' {
        Mock Test-Cmd { $true } -ParameterFilter { $Name -eq 'claude' }
        Mock Get-BoochWinInstalledPlugin { @('codex', 'pike-todo', 'orphan-plugin') }
        Mock Get-BoochWinRegisteredMarketplace { @() }
        $plan = @(Get-BoochWinAutoremovePlan -KeepPlugins @('codex', 'pike-todo') `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $plugins = @($plan | Where-Object Kind -eq 'plugin')
        $plugins.Count | Should -Be 1
        $plugins[0].Id | Should -Be 'orphan-plugin'
    }

    It 'KeepMarketplaces に無い登録済み marketplace だけを marketplace 候補にする' {
        Mock Test-Cmd { $true } -ParameterFilter { $Name -eq 'claude' }
        Mock Get-BoochWinInstalledPlugin { @() }
        Mock Get-BoochWinRegisteredMarketplace { @('claude-plugins-official', 'pike', 'stray-mkt') }
        $plan = @(Get-BoochWinAutoremovePlan -KeepMarketplaces @('claude-plugins-official', 'pike') `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $mkts = @($plan | Where-Object Kind -eq 'marketplace')
        $mkts.Count | Should -Be 1
        $mkts[0].Id | Should -Be 'stray-mkt'
    }

    It '未登録かつ Keep 外の marketplaces clone だけを mktclone 候補にする' {
        Mock Test-Cmd { $true } -ParameterFilter { $Name -eq 'claude' }
        Mock Get-BoochWinInstalledPlugin { @() }
        Mock Get-BoochWinRegisteredMarketplace { @('pike') }
        New-Item -ItemType Directory -Path (Join-Path $script:MkRoot 'pike')  -Force | Out-Null  # 登録済み → 除外
        New-Item -ItemType Directory -Path (Join-Path $script:MkRoot 'ghost') -Force | Out-Null  # 未登録 → 候補
        $plan = @(Get-BoochWinAutoremovePlan -KeepMarketplaces @('claude-plugins-official') `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $clones = @($plan | Where-Object Kind -eq 'mktclone')
        $clones.Count | Should -Be 1
        $clones[0].Id | Should -Be 'ghost'
        $clones[0].Target | Should -Be (Join-Path $script:MkRoot 'ghost')
    }

    It 'KeepCodexSkills に無い codex skill だけを codexskill 候補にする' {
        Mock Test-Cmd { $true } -ParameterFilter { $Name -eq 'claude' }
        Mock Get-BoochWinInstalledPlugin { @() }
        Mock Get-BoochWinRegisteredMarketplace { @() }
        New-Item -ItemType Directory -Path (Join-Path $script:CxRoot 'pike-todo') -Force | Out-Null   # Keep → 除外
        New-Item -ItemType Directory -Path (Join-Path $script:CxRoot 'leftover')  -Force | Out-Null   # 候補
        $plan = @(Get-BoochWinAutoremovePlan -KeepCodexSkills @('pike-todo') `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $skills = @($plan | Where-Object Kind -eq 'codexskill')
        $skills.Count | Should -Be 1
        $skills[0].Id | Should -Be 'leftover'
    }

    It 'ドット始まりの内部ディレクトリ (.system / .git) は候補にしない' {
        Mock Test-Cmd { $true } -ParameterFilter { $Name -eq 'claude' }
        Mock Get-BoochWinInstalledPlugin { @() }
        Mock Get-BoochWinRegisteredMarketplace { @() }
        New-Item -ItemType Directory -Path (Join-Path $script:MkRoot '.git')    -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:CxRoot '.system') -Force | Out-Null
        $plan = @(Get-BoochWinAutoremovePlan -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $plan.Count | Should -Be 0
    }

    It 'claude 不在なら plugin/marketplace/mktclone は出さず codexskill だけ判定する' {
        Mock Test-Cmd { $false } -ParameterFilter { $Name -eq 'claude' }
        New-Item -ItemType Directory -Path (Join-Path $script:MkRoot 'ghost')   -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:CxRoot 'leftover') -Force | Out-Null
        $plan = @(Get-BoochWinAutoremovePlan -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        @($plan | Where-Object Kind -in 'plugin', 'marketplace', 'mktclone').Count | Should -Be 0
        @($plan | Where-Object Kind -eq 'codexskill').Count | Should -Be 1
    }

    It '宣言と一致していれば空の plan を返す' {
        Mock Test-Cmd { $true } -ParameterFilter { $Name -eq 'claude' }
        Mock Get-BoochWinInstalledPlugin { @('codex') }
        Mock Get-BoochWinRegisteredMarketplace { @('pike') }
        $plan = @(Get-BoochWinAutoremovePlan -KeepPlugins @('codex') -KeepMarketplaces @('pike') `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $plan.Count | Should -Be 0
    }
}

Describe 'Get-BoochWinInstalledPlugin' {
    It '❯ 行の name@marketplace から name を拾う' {
        Mock Test-Cmd { $true } -ParameterFilter { $Name -eq 'claude' }
        Mock Get-ClaudePluginList { "❯ codex@openai-codex`n  Version: 1.0`n❯ pike-todo@pike`n  Version: 2.0" }
        $names = @(Get-BoochWinInstalledPlugin)
        $names | Should -Be @('codex', 'pike-todo')
    }

    It 'claude 不在なら空を返す' {
        Mock Test-Cmd { $false } -ParameterFilter { $Name -eq 'claude' }
        @(Get-BoochWinInstalledPlugin).Count | Should -Be 0
    }
}

Describe 'Remove-BoochWinDirUnder' {
    BeforeEach {
        $script:Root2 = Join-Path $TestDrive ('r_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root2 -Force | Out-Null
    }

    It 'Root 配下の実ディレクトリを削除する' {
        $target = Join-Path $script:Root2 'child'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Remove-BoochWinDirUnder -Path $target -Root $script:Root2 | Should -BeTrue
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'Root 外のパスは削除せず $false を返す' {
        $outside = Join-Path $TestDrive ('outside_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Remove-BoochWinDirUnder -Path $outside -Root $script:Root2 | Should -BeFalse
        Test-Path -LiteralPath $outside | Should -BeTrue
    }

    It '不在パスは $false を返す' {
        Remove-BoochWinDirUnder -Path (Join-Path $script:Root2 'nope') -Root $script:Root2 | Should -BeFalse
    }
}

Describe 'Invoke-BoochWinAutoremove' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}; Mock Write-Fail {}
    }

    It '候補ゼロなら確認せず何も削除しない' {
        Mock Get-BoochWinAutoremovePlan { @() }
        Mock Invoke-BoochWinAutoremoveOne { $true }
        Mock Read-Host { 'y' }
        Invoke-BoochWinAutoremove
        Should -Invoke Invoke-BoochWinAutoremoveOne -Times 0
        Should -Invoke Read-Host -Times 0
    }

    It '--dry-run は一覧提示のみで削除も確認もしない' {
        Mock Get-BoochWinAutoremovePlan { @([pscustomobject]@{ Kind = 'plugin'; Id = 'x'; Target = 'x'; Desc = '' }) }
        Mock Invoke-BoochWinAutoremoveOne { $true }
        Mock Read-Host { 'y' }
        Invoke-BoochWinAutoremove -DryRun
        Should -Invoke Invoke-BoochWinAutoremoveOne -Times 0
        Should -Invoke Read-Host -Times 0
    }

    It '確認で n なら削除しない' {
        Mock Get-BoochWinAutoremovePlan { @([pscustomobject]@{ Kind = 'plugin'; Id = 'x'; Target = 'x'; Desc = '' }) }
        Mock Invoke-BoochWinAutoremoveOne { $true }
        Mock Read-Host { 'n' }
        Invoke-BoochWinAutoremove
        Should -Invoke Invoke-BoochWinAutoremoveOne -Times 0
    }

    It '-AssumeYes なら確認せず各候補を削除する' {
        Mock Get-BoochWinAutoremovePlan {
            @(
                [pscustomobject]@{ Kind = 'plugin';      Id = 'a'; Target = 'a'; Desc = '' },
                [pscustomobject]@{ Kind = 'codexskill';  Id = 'b'; Target = 'b'; Desc = '' }
            )
        }
        Mock Invoke-BoochWinAutoremoveOne { $true }
        Mock Read-Host { 'n' }
        Invoke-BoochWinAutoremove -AssumeYes
        Should -Invoke Read-Host -Times 0
        Should -Invoke Invoke-BoochWinAutoremoveOne -Times 2
    }
}
