#requires -Version 5.1
# lib/ghext.ps1 を検証する (Pester 5)。gh 本体は叩かず、一覧と認証の判定を Mock で差し替え、
# install は関数でシャドウして渡された引数だけを記録する (コマンド解決は Function > Native)。
#
# 見たいのは次の 3 点。
#   - `gh extension list` の 3 列目を版として読むこと (取り違えると doctor が常に不一致を出す)
#   - upgrade ではなく `install --force` を使うこと (upgrade は pin 付きを黙って飛ばす)
#   - gh が無い・未認証のときに install を叩かないこと

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'github.ps1')
    . (Join-Path $lib 'doctor.ps1')
    . (Join-Path $lib 'ghext.ps1')

    $script:ListLine = "gh actions-lock`tgithub/gh-actions-lock`tv0.4.1"
}

Describe 'Get-GhExtensionVersion' {
    It 'owner/repo が一致する行の 3 列目を返す' {
        $list = @("gh foo`tsomeone/gh-foo`tv1.0.0", $script:ListLine)
        Get-GhExtensionVersion -List $list -Repo 'github/gh-actions-lock' | Should -Be 'v0.4.1'
    }

    It '一覧に無ければ空文字' {
        Get-GhExtensionVersion -List @($script:ListLine) -Repo 'someone/gh-foo' | Should -BeNullOrEmpty
    }
}

Describe 'Get-GhExtensionLabel' {
    It 'repo 名の gh- を落として gh を前置する' {
        Get-GhExtensionLabel 'github/gh-actions-lock' | Should -Be 'gh actions-lock'
    }
}

Describe 'Install-GhExtensions' {
    BeforeEach {
        $global:GhCalls = @()
        function global:gh { $global:GhCalls += ($args -join ' '); $global:LASTEXITCODE = 0 }
        Mock Write-Host {}
    }

    AfterEach {
        Remove-Item Function:global:gh -ErrorAction SilentlyContinue
        Remove-Variable -Name GhCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It '認証済みなら upgrade ではなく install --force で全部入れ、一覧は前後 1 回ずつ取る' {
        Mock Test-GhAuthenticated { $true }
        Mock Get-GhExtensionList { @($script:ListLine) }
        Mock Write-Fail {}
        Install-GhExtensions -Repos @('github/gh-actions-lock', 'someone/gh-foo')
        $global:GhCalls | Should -Contain 'extension install --force github/gh-actions-lock'
        $global:GhCalls | Should -Contain 'extension install --force someone/gh-foo'
        $global:GhCalls | Where-Object { $_ -like 'extension upgrade*' } | Should -BeNullOrEmpty
        Should -Invoke Get-GhExtensionList -Times 2 -Exactly
        # gh-foo は install 後の一覧に無いので、成功扱いにせず失敗として出す。
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*someone/gh-foo*' }
    }

    It 'install が失敗したら gh の出力の最後の行を添えて失敗を出す' {
        Mock Test-GhAuthenticated { $true }
        Mock Get-GhExtensionList { @() }
        Mock Write-Fail {}
        function global:gh { 'line1'; 'no asset for windows-amd64'; $global:LASTEXITCODE = 1 }
        Install-GhExtensions -Repos @('github/gh-actions-lock')
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*no asset for windows-amd64' }
    }

    It '未認証なら install を叩かない' {
        Mock Test-GhAuthenticated { $false }
        Install-GhExtensions -Repos @('github/gh-actions-lock')
        $global:GhCalls.Count | Should -Be 0
    }

    It 'gh が無ければ install を叩かない' {
        Mock Test-Cmd { $false } -ParameterFilter { $Name -eq 'gh' }
        Mock Test-GhAuthenticated { throw '呼ばれてはいけない' }
        Install-GhExtensions -Repos @('github/gh-actions-lock')
        $global:GhCalls.Count | Should -Be 0
    }

    It '一覧が空なら何もしない' {
        Mock Test-GhAuthenticated { throw '呼ばれてはいけない' }
        Install-GhExtensions -Repos @()
        $global:GhCalls.Count | Should -Be 0
    }
}

Describe 'Test-GhAuthenticated' {
    AfterEach {
        Remove-Item Function:global:gh -ErrorAction SilentlyContinue
        Remove-Variable -Name GhCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'github.com の使用中のアカウントだけを見る (別ホストの期限切れで未認証にしない)' {
        $global:GhCalls = @()
        function global:gh { $global:GhCalls += ($args -join ' '); $global:LASTEXITCODE = 0 }
        Test-GhAuthenticated | Should -BeTrue
        $global:GhCalls | Should -Contain 'auth status --hostname github.com --active'
    }
}

Describe 'Get-GhExtensionLatestTag' {
    AfterEach { Remove-Item Function:global:gh -ErrorAction SilentlyContinue }

    It '認証済みの gh で取れればその値を返す' {
        function global:gh { 'v0.5.0'; $global:LASTEXITCODE = 0 }
        Mock Get-GitHubLatestReleaseTag { throw '呼ばれてはいけない' }
        Get-GhExtensionLatestTag -Repo 'github/gh-actions-lock' | Should -Be 'v0.5.0'
    }

    It 'gh で取れなければ REST に戻す' {
        function global:gh { $global:LASTEXITCODE = 1 }
        Mock Get-GitHubLatestReleaseTag { 'v0.4.1' }
        Get-GhExtensionLatestTag -Repo 'github/gh-actions-lock' | Should -Be 'v0.4.1'
    }
}

Describe 'Get-GhExtensionDoctorTools' {
    It '導入済みなら Show-ToolList が OK にし、版を Ver から出す' {
        Mock Get-GhExtensionList { @($script:ListLine) }
        $tools = @(Get-GhExtensionDoctorTools -Repos @('github/gh-actions-lock'))
        $tools.Count | Should -Be 1
        $tools[0].Label | Should -Be 'gh actions-lock'
        Test-ToolInstalled -Tool $tools[0] | Should -BeTrue
        & $tools[0].Ver | Should -Be 'v0.4.1'
    }

    It 'gh があっても拡張が一覧に無ければ未導入 (missing) になる' {
        Mock Get-GhExtensionList { @() }
        Mock Test-Cmd { $true }
        Mock Write-Host {}
        Mock Get-GhExtensionLatestTag { 'v0.4.1' }
        $tools = @(Get-GhExtensionDoctorTools -Repos @('github/gh-actions-lock'))
        Show-ToolList -Tools $tools | Should -BeTrue
        Should -Invoke Get-GhExtensionLatestTag -Times 0
    }

    It 'Latest は lib の関数をそのまま呼べる (別スコープに閉じない)' {
        Mock Get-GhExtensionList { @($script:ListLine) }
        Mock Get-GhExtensionLatestTag { 'v9.9.9' } -ParameterFilter { $Repo -eq 'github/gh-actions-lock' }
        $tools = @(Get-GhExtensionDoctorTools -Repos @('github/gh-actions-lock'))
        & $tools[0].Latest | Should -Be 'v9.9.9'
    }
}
