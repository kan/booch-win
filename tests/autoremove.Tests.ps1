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

# 実装は lib/claude.ps1 の Get-ClaudeMarketplaceName へ委譲している。plan 側のテストは
# この関数を丸ごと Mock するので、委譲先の綴りを間違えても parse も Pester も通ってしまい、
# 実機で初めて CommandNotFoundException になる (PowerShell の parse は未定義関数を検出しない)。
# ここだけは Mock せずに実体を通す。
Describe 'Get-BoochWinRegisteredMarketplace' {
    It 'Get-ClaudeMarketplaceName へ委譲する' {
        Mock Get-ClaudeMarketplaceName { @('acme', 'openai-codex') }
        Get-BoochWinRegisteredMarketplace | Should -Be @('acme', 'openai-codex')
        Should -Invoke Get-ClaudeMarketplaceName -Times 1
    }
}

Describe 'Get-BoochWinAutoremovePlan' {
    # 注: claude の有無 (Test-ClaudeInstalled) の mock は各 It で明示する。BeforeEach の既定を
    # It で上書きすると mock の優先順位が紛らわしくなるため (実 claude を誤って叩く)。
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}; Mock Write-Fail {}
        $script:MkRoot = Join-Path $TestDrive ('mk_' + [guid]::NewGuid().ToString('N'))
        $script:CxRoot = Join-Path $TestDrive ('cx_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:MkRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $script:CxRoot -Force | Out-Null
    }

    It 'KeepPlugins に無い導入済みプラグインだけを plugin 候補にする' {
        Mock Test-ClaudeInstalled { $true }
        Mock Get-BoochWinInstalledPlugin { @('codex', 'pike-todo', 'orphan-plugin') }
        Mock Get-BoochWinRegisteredMarketplace { @() }
        $plan = @(Get-BoochWinAutoremovePlan -KeepPlugins @('codex', 'pike-todo') `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $plugins = @($plan | Where-Object Kind -eq 'plugin')
        $plugins.Count | Should -Be 1
        $plugins[0].Id | Should -Be 'orphan-plugin'
    }

    It 'KeepMarketplaces に無い登録済み marketplace だけを marketplace 候補にする' {
        Mock Test-ClaudeInstalled { $true }
        Mock Get-BoochWinInstalledPlugin { @() }
        Mock Get-BoochWinRegisteredMarketplace { @('claude-plugins-official', 'pike', 'stray-mkt') }
        $plan = @(Get-BoochWinAutoremovePlan -KeepMarketplaces @('claude-plugins-official', 'pike') `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $mkts = @($plan | Where-Object Kind -eq 'marketplace')
        $mkts.Count | Should -Be 1
        $mkts[0].Id | Should -Be 'stray-mkt'
    }

    It '未登録かつ Keep 外の marketplaces clone だけを mktclone 候補にする' {
        Mock Test-ClaudeInstalled { $true }
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
        Mock Test-ClaudeInstalled { $true }
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
        Mock Test-ClaudeInstalled { $true }
        Mock Get-BoochWinInstalledPlugin { @() }
        Mock Get-BoochWinRegisteredMarketplace { @() }
        New-Item -ItemType Directory -Path (Join-Path $script:MkRoot '.git')    -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:CxRoot '.system') -Force | Out-Null
        $plan = @(Get-BoochWinAutoremovePlan -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $plan.Count | Should -Be 0
    }

    It 'claude 不在なら plugin/marketplace/mktclone は出さず codexskill だけ判定する' {
        Mock Test-ClaudeInstalled { $false }
        New-Item -ItemType Directory -Path (Join-Path $script:MkRoot 'ghost')   -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:CxRoot 'leftover') -Force | Out-Null
        $plan = @(Get-BoochWinAutoremovePlan -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        @($plan | Where-Object Kind -in 'plugin', 'marketplace', 'mktclone').Count | Should -Be 0
        @($plan | Where-Object Kind -eq 'codexskill').Count | Should -Be 1
    }

    It '宣言と一致していれば空の plan を返す' {
        Mock Test-ClaudeInstalled { $true }
        Mock Get-BoochWinInstalledPlugin { @('codex') }
        Mock Get-BoochWinRegisteredMarketplace { @('pike') }
        $plan = @(Get-BoochWinAutoremovePlan -KeepPlugins @('codex') -KeepMarketplaces @('pike') `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $plan.Count | Should -Be 0
    }

    It 'ClaudeConfigDirs を複数渡すと dir ごとに走査し ConfigDir を付ける' {
        # 片方の dir しか見ないと、もう片方のリスト外プラグインが永久に残る。
        Mock Test-ClaudeInstalled { $true }
        Mock Get-BoochWinInstalledPlugin {
            if ($env:CLAUDE_CONFIG_DIR) { @('orphan-alt') } else { @('orphan-default') }
        }
        Mock Get-BoochWinRegisteredMarketplace { @() }
        $alt  = Join-Path $TestDrive ('cfg_' + [guid]::NewGuid().ToString('N'))
        $plan = @(Get-BoochWinAutoremovePlan -ClaudeConfigDirs @('', $alt) `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $plugins = @($plan | Where-Object Kind -eq 'plugin')
        $plugins.Count | Should -Be 2
        ($plugins | Where-Object Id -eq 'orphan-default').ConfigDir | Should -BeNullOrEmpty
        ($plugins | Where-Object Id -eq 'orphan-alt').ConfigDir     | Should -Be $alt
    }

    It '走査後は呼び出し元の CLAUDE_CONFIG_DIR へ戻す' {
        # 見るのは「未設定へ戻る」ではなく「呼び出し元の値へ戻る」。テストを走らせる端末が
        # CLAUDE_CONFIG_DIR を設定していることはある (アカウントを切り替えるラッパー等) ので、
        # 未設定を前提にすると機構は正しいのにその端末でだけ落ちる。両方の呼び出し元状態を見る。
        Mock Test-ClaudeInstalled { $true }
        Mock Get-BoochWinInstalledPlugin { @() }
        Mock Get-BoochWinRegisteredMarketplace { @() }
        $alt   = Join-Path $TestDrive ('cfg_' + [guid]::NewGuid().ToString('N'))
        $saved = $env:CLAUDE_CONFIG_DIR
        try {
            foreach ($caller in @('', (Join-Path $TestDrive 'caller'))) {
                Set-ClaudeConfigDir $caller
                Get-BoochWinAutoremovePlan -ClaudeConfigDirs @('', $alt) `
                    -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot | Out-Null
                if ($caller) {
                    $env:CLAUDE_CONFIG_DIR | Should -Be $caller
                } else {
                    (Test-Path Env:CLAUDE_CONFIG_DIR) | Should -BeFalse
                }
            }
        } finally {
            Set-ClaudeConfigDir $saved
        }
    }

    It 'MarketplacesRoot 未指定なら mktclone の走査先を config dir 配下から導出する' {
        Mock Test-ClaudeInstalled { $true }
        Mock Get-BoochWinInstalledPlugin { @() }
        Mock Get-BoochWinRegisteredMarketplace { @() }
        $alt = Join-Path $TestDrive ('cfg_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $alt 'plugins\marketplaces\ghost') -Force | Out-Null
        $plan = @(Get-BoochWinAutoremovePlan -ClaudeConfigDirs @($alt) -CodexSkillsRoot $script:CxRoot)
        $mk = @($plan | Where-Object Kind -eq 'mktclone')
        $mk.Count       | Should -Be 1
        $mk[0].Id       | Should -Be 'ghost'
        $mk[0].ConfigDir | Should -Be $alt
    }

    It 'codexskill は config dir に依らないので ConfigDir を持たない' {
        Mock Test-ClaudeInstalled { $true }
        Mock Get-BoochWinInstalledPlugin { @() }
        Mock Get-BoochWinRegisteredMarketplace { @() }
        New-Item -ItemType Directory -Path (Join-Path $script:CxRoot 'leftover') -Force | Out-Null
        $alt  = Join-Path $TestDrive ('cfg_' + [guid]::NewGuid().ToString('N'))
        $plan = @(Get-BoochWinAutoremovePlan -ClaudeConfigDirs @('', $alt) `
                -MarketplacesRoot $script:MkRoot -CodexSkillsRoot $script:CxRoot)
        $cx = @($plan | Where-Object Kind -eq 'codexskill')
        $cx.Count | Should -Be 1                     # dir の数だけ重複しない
        $cx[0].ConfigDir | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-BoochWinAutoremoveOne' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}; Mock Write-Fail {}
    }

    It 'mktclone の安全弁 Root を ConfigDir 配下から導出する' {
        $alt    = Join-Path $TestDrive ('cfg_' + [guid]::NewGuid().ToString('N'))
        $target = Join-Path $alt 'plugins\marketplaces\ghost'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Invoke-BoochWinAutoremoveOne -Kind 'mktclone' -Target $target -ConfigDir $alt | Should -BeTrue
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It '別の config dir を指定すると安全弁に弾かれて消さない' {
        $alt    = Join-Path $TestDrive ('cfg_' + [guid]::NewGuid().ToString('N'))
        $other  = Join-Path $TestDrive ('cfg_' + [guid]::NewGuid().ToString('N'))
        $target = Join-Path $alt 'plugins\marketplaces\ghost'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Invoke-BoochWinAutoremoveOne -Kind 'mktclone' -Target $target -ConfigDir $other | Should -BeFalse
        Test-Path -LiteralPath $target | Should -BeTrue
    }
}

Describe 'Get-BoochWinInstalledPlugin' {
    It '❯ 行の name@marketplace から name を拾う' {
        Mock Test-ClaudeInstalled { $true }
        Mock Get-ClaudePluginList { "❯ codex@openai-codex`n  Version: 1.0`n❯ pike-todo@pike`n  Version: 2.0" }
        $names = @(Get-BoochWinInstalledPlugin)
        $names | Should -Be @('codex', 'pike-todo')
    }

    It 'claude 不在なら空を返す' {
        Mock Test-ClaudeInstalled { $false }
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
