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
    function powershell { }
    if (-not (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) {
        # ParameterFilter で $MainPackage を見るので、引数を宣言しておく。
        function Add-AppxPackage { param([switch]$RegisterByFamilyName, [string]$MainPackage) $null = $RegisterByFamilyName, $MainPackage }
    }

    # main を実行せず関数定義だけ読み込む（win.ps1 は param を持たず env で制御する）。
    $env:BOOCH_WIN_NORUN = '1'
    . $script:WinPs1
}

AfterAll {
    Remove-Item Env:\BOOCH_WIN_NORUN -ErrorAction SilentlyContinue
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
    It 'winget の用意を Initialize-Winget に任せる' {
        Mock Initialize-Winget { }
        Initialize-Prereq
        Should -Invoke Initialize-Winget -Times 1 -Exactly
    }
}

Describe 'Initialize-Winget' {
    BeforeEach {
        Mock Write-Ok { }
        Mock Write-Step { }
        Mock Write-Warn { }
        Mock Write-Host { }
        Mock Update-SessionPath { }
        Mock Start-Sleep { }
        Mock Register-AppInstaller { }
        Mock Install-WingetFromGallery { 0 }
        Mock Read-Host { 'y' }
        # Test-Command winget が呼ばれるたびに $script:WingetSeen を先頭から返す (尽きたら最後の値)。
        $script:WingetSeen = @($false)
        $script:WingetCalls = 0
        Mock Test-Command {
            $i = [Math]::Min($script:WingetCalls, $script:WingetSeen.Count - 1)
            $script:WingetCalls++
            $script:WingetSeen[$i]
        } -ParameterFilter { $Name -eq 'winget' }
    }

    It 'winget があれば何もしない' {
        $script:WingetSeen = @($true)
        Initialize-Winget
        Should -Invoke Register-AppInstaller -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It '登録で winget が現れれば、導入するか聞かない' {
        $script:WingetSeen = @($false, $true)
        Initialize-Winget
        Should -Invoke Register-AppInstaller -Times 1 -Exactly
        Should -Invoke Update-SessionPath -Times 1 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Install-WingetFromGallery -Times 0 -Exactly
    }

    It '登録の直後に現れなくても、少し待って現れれば導入するか聞かない' {
        $script:WingetSeen = @($false, $false, $false, $true)
        Initialize-Winget
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It '登録で現れなければ聞き、承諾されたら導入する' {
        # 最初の確認 + 登録後の 5 回 (いずれも無い) の後、導入後の確認で現れる。
        $script:WingetSeen = @($false, $false, $false, $false, $false, $false, $true)
        Initialize-Winget
        Should -Invoke Install-WingetFromGallery -Times 1 -Exactly
        Should -Invoke Update-SessionPath -Times 2 -Exactly
    }

    It '導入が exit 0 で終わっても winget が現れなければ throw する' {
        Mock Install-WingetFromGallery { 0 }
        { Initialize-Winget } | Should -Throw -ExpectedMessage '*apps.microsoft.com*'
        Should -Invoke Install-WingetFromGallery -Times 1 -Exactly
    }

    It '断られたら導入せず、手で入れる方法を示して throw する' {
        Mock Read-Host { 'n' }
        { Initialize-Winget } | Should -Throw -ExpectedMessage '*Repair-WinGetPackageManager*'
        Should -Invoke Install-WingetFromGallery -Times 0 -Exactly
    }

    It '導入しても現れなければ throw する' {
        Mock Install-WingetFromGallery { 1 }
        { Initialize-Winget } | Should -Throw -ExpectedMessage '*apps.microsoft.com*'
        Should -Invoke Install-WingetFromGallery -Times 1 -Exactly
    }
}

Describe 'Register-AppInstaller' {
    It 'App Installer が無く登録に失敗しても throw しない' {
        Mock Add-AppxPackage { throw 'package not found' }
        { Register-AppInstaller } | Should -Not -Throw
        Should -Invoke Add-AppxPackage -Times 1 -Exactly -ParameterFilter {
            $MainPackage -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
        }
    }
}

Describe 'Install-WingetFromGallery' {
    It '子の Windows PowerShell を Bypass で起動し、終了コードだけを返す' {
        Mock powershell { 'noise'; $global:LASTEXITCODE = 3 }
        Mock Out-Host { }
        Install-WingetFromGallery | Should -Be 3
        Should -Invoke powershell -Times 1 -Exactly -ParameterFilter {
            ($args -contains '-EncodedCommand') -and ($args -contains 'Bypass')
        }
    }

    It '子へ渡すスクリプトは公式の手順を CurrentUser で行う' {
        $script:Encoded = $null
        Mock powershell { $script:Encoded = $args[$args.IndexOf('-EncodedCommand') + 1]; $global:LASTEXITCODE = 0 }
        Mock Out-Host { }
        Install-WingetFromGallery | Out-Null
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:Encoded))
        $decoded | Should -Match 'Install-Module -Name Microsoft\.WinGet\.Client .*-Scope CurrentUser'
        $decoded | Should -Match 'Repair-WinGetPackageManager -AllUsers'
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($decoded, [ref]$null, [ref]$errs)
        $errs.Count | Should -Be 0
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

Describe 'Invoke-Native' {
    # PS5.1 で Stop のまま native が stderr に書くと terminating になる問題への継ぎ目。
    It '実行中は Continue に緩め、後で元へ戻す' {
        $ErrorActionPreference = 'Stop'
        $inside = Invoke-Native { $ErrorActionPreference }
        $inside | Should -Be 'Continue'
        $ErrorActionPreference | Should -Be 'Stop'
    }
    It '例外時も ErrorActionPreference を復元する' {
        $ErrorActionPreference = 'Stop'
        { Invoke-Native { throw 'x' } } | Should -Throw
        $ErrorActionPreference | Should -Be 'Stop'
    }
}

