#requires -Version 5.1
# booch-win/win.ps1 のロジックを実システムに触れずに検証する（Pester 5）。
# 外部コマンド（winget / gh / git）と Test-Command の継ぎ目をモックする。

BeforeAll {
    $script:WinPs1 = Join-Path (Split-Path $PSScriptRoot -Parent) 'win.ps1'

    # 実行時に存在しない可能性のある外部コマンドも Mock 対象にできるよう、
    # 同名の関数スタブを先に定義しておく（& winget 等はこの関数へ解決される）。
    function winget { }
    function gh { }
    function git { }

    # main を実行せず関数定義だけ読み込む。
    . $script:WinPs1 -NoRun
}

Describe 'Test-Command' {
    It '存在するコマンドで $true を返す' {
        Test-Command 'Get-Item' | Should -BeTrue
    }
    It '存在しないコマンドで $false を返す' {
        Test-Command 'definitely-not-a-real-command-xyz' | Should -BeFalse
    }
}

Describe 'Initialize-Prereq' {
    It 'winget が無ければ throw する' {
        Mock Test-Command { $false } -ParameterFilter { $Name -eq 'winget' }
        { Initialize-Prereq } | Should -Throw -ExpectedMessage '*winget*'
    }
    It 'winget があれば throw しない' {
        Mock Test-Command { $true } -ParameterFilter { $Name -eq 'winget' }
        Mock Write-Ok { }
        { Initialize-Prereq } | Should -Not -Throw
    }
}

Describe 'Install-IfMissing' {
    BeforeEach {
        Mock Write-Ok { }
        Mock Write-Step { }
        Mock winget { $global:LASTEXITCODE = 0 }
    }

    It '既にあるなら winget を呼ばない（冪等）' {
        Mock Test-Command { $true }
        Install-IfMissing -Cmd 'git' -WingetId 'Git.Git' -Label 'Git'
        Should -Invoke winget -Times 0
    }

    It '無ければ winget install を当該 ID で呼ぶ' {
        Mock Test-Command { $false }
        Install-IfMissing -Cmd 'git' -WingetId 'Git.Git' -Label 'Git'
        Should -Invoke winget -Times 1 -ParameterFilter { $args -contains 'Git.Git' }
    }

    It 'winget が失敗（exit!=0）したら throw する' {
        Mock Test-Command { $false }
        Mock winget { $global:LASTEXITCODE = 1 }
        { Install-IfMissing -Cmd 'git' -WingetId 'Git.Git' -Label 'Git' } |
            Should -Throw -ExpectedMessage '*Git*'
    }
}

Describe 'Connect-GitHub' {
    BeforeEach { Mock Write-Ok { }; Mock Write-Step { } }

    It '認証済みなら gh auth login を呼ばない' {
        Mock gh { $global:LASTEXITCODE = 0 }   # gh auth status 成功
        Connect-GitHub
        Should -Invoke gh -Times 1 -ParameterFilter { $args -contains 'status' }
        Should -Invoke gh -Times 0 -ParameterFilter { $args -contains 'login' }
    }

    It '未認証なら gh auth login を呼ぶ' {
        # status は失敗、login は成功させる
        $script:calls = 0
        Mock gh {
            $script:calls++
            if ($args -contains 'status') { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
        }
        Connect-GitHub
        Should -Invoke gh -Times 1 -ParameterFilter { $args -contains 'login' }
    }
}

Describe 'Get-Repo' {
    BeforeEach { Mock Write-Step { }; Mock gh { $global:LASTEXITCODE = 0 }; Mock git { $global:LASTEXITCODE = 0 } }

    It '.git があれば pull する' {
        Mock Test-Path { $true }
        Get-Repo -RepoSlug 'youraccount/dotfiles' -Target (Join-Path $TestDrive 'dot')
        Should -Invoke git -Times 1 -ParameterFilter { $args -contains 'pull' }
        Should -Invoke gh  -Times 0
    }

    It '.git が無ければ clone する（submodule ごと）' {
        Mock Test-Path { $false }
        Get-Repo -RepoSlug 'youraccount/dotfiles' -Target (Join-Path $TestDrive 'dot')
        Should -Invoke gh  -Times 1 -ParameterFilter { $args -contains 'clone' }
        Should -Invoke gh  -Times 1 -ParameterFilter { $args -contains '--recurse-submodules' }
    }

    It 'clone / pull いずれでも submodule update を実行する' {
        Mock Test-Path { $false }
        Get-Repo -RepoSlug 'youraccount/dotfiles' -Target (Join-Path $TestDrive 'dot')
        Should -Invoke git -Times 1 -ParameterFilter { $args -contains 'submodule' }

        Mock Test-Path { $true }
        Get-Repo -RepoSlug 'youraccount/dotfiles' -Target (Join-Path $TestDrive 'dot')
        Should -Invoke git -Times 2 -ParameterFilter { $args -contains 'submodule' }
    }
}

Describe 'Invoke-DotfilesWin' {
    It 'エントリが無ければ throw する' {
        Mock Test-Path { $false }
        Mock Write-Step { }
        { Invoke-DotfilesWin -Target (Join-Path $TestDrive 'dot') } |
            Should -Throw -ExpectedMessage '*setup-win/dotfiles-win.ps1*'
    }
}

Describe 'Invoke-Main' {
    It 'Repo 未指定なら（副作用の前に）throw する' {
        { Invoke-Main -RepoSlug '' -Target (Join-Path $TestDrive 'dot') } |
            Should -Throw -ExpectedMessage '*BOOCH_WIN_REPO*'
    }
}

