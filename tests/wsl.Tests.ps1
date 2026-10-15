#requires -Version 5.1
# lib/wsl.ps1 を検証する (Pester 5)。wsl.exe を叩かずに、導入判定、版の比較、状態の返り分けを確認する。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')
    . (Join-Path $lib 'doctor.ps1')
    . (Join-Path $lib 'github.ps1')
    . (Join-Path $lib 'wsl.ps1')

    # 実行時に存在しない可能性のある外部コマンドもモックできるよう関数スタブを置く。
    function wsl.exe { }
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        function Get-AppxPackage { }
    }
}

Describe 'Get-WslDistros' {
    It 'wsl.exe の UTF-16 出力 (null 挟み) から名前を取り出す' {
        # コンソールのエンコーディング次第で 1 文字ごとに null が入るケースを模す。
        Mock Invoke-Quiet { $global:LASTEXITCODE = 0; "U`0b`0u`0n`0t`0u`0-`02`06`0.`00`04`0`r`n" }
        Get-WslDistros | Should -Be @('Ubuntu-26.04')
    }

    It '空出力なら空配列' {
        Mock Invoke-Quiet { $global:LASTEXITCODE = 0; '' }
        (Get-WslDistros).Count | Should -Be 0
    }

    It 'wsl.exe が非 0 で終わったら案内文を名前として返さず空配列' {
        Mock Invoke-Quiet { $global:LASTEXITCODE = 1; "There are no running distributions.`r`n" }
        (Get-WslDistros -Running).Count | Should -Be 0
    }

    It 'wsl.exe が無ければ空配列 (エラー文を名前として返さない)' {
        Mock Get-Command { }
        Mock Invoke-Quiet { $global:LASTEXITCODE = 0; "wsl.exe : The term 'wsl.exe' is not recognized`r`n" }
        (Get-WslDistros).Count | Should -Be 0
        Should -Invoke Invoke-Quiet -Times 0 -Exactly
    }

    It '-Running なら起動中の一覧を引く' {
        Mock wsl.exe { $global:LASTEXITCODE = 0; if ($args -contains '--running') { 'Ubuntu-26.04' } else { 'Other' } }
        Get-WslDistros -Running | Should -Be @('Ubuntu-26.04')
        Get-WslDistros | Should -Be @('Other')
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

Describe 'Get-WslPackageVersion' {
    It 'Store パッケージの 4 要素の版を x.y.z にそろえる' {
        Mock Get-AppxPackage { [pscustomobject]@{ Version = '3.0.3.0' } }
        Get-WslPackageVersion | Should -Be '3.0.3'
    }

    It '未導入なら空' {
        Mock Get-AppxPackage { }
        Get-WslPackageVersion | Should -Be ''
    }
}

Describe 'Get-WslLatestVersion' {
    It 'GitHub の最新タグから版を取り出す' {
        Mock Get-GitHubLatestReleaseTag { '3.0.4' }
        Get-WslLatestVersion -Repo 'microsoft/WSL' | Should -Be '3.0.4'
        Should -Invoke Get-GitHubLatestReleaseTag -Times 1 -Exactly -ParameterFilter { $Repo -eq 'microsoft/WSL' }
    }

    It '取れなければ空' {
        Mock Get-GitHubLatestReleaseTag { '' }
        Get-WslLatestVersion -Repo 'microsoft/WSL' | Should -Be ''
    }
}

Describe 'Test-LaunchedFromWsl' {
    It '祖先に wsl 系のプロセスがあれば真' {
        foreach ($n in 'wsl.exe', 'wslhost.exe', 'wslrelay.exe') {
            Mock Get-CurrentProcessAncestor { @([pscustomobject]@{ ProcessId = 2; Name = 'pwsh.exe' }, [pscustomobject]@{ ProcessId = 3; Name = $n }) }
            Test-LaunchedFromWsl | Should -BeTrue
        }
    }

    It '無ければ偽 (名前が似ているだけのものは数えない)' {
        Mock Get-CurrentProcessAncestor { @([pscustomobject]@{ ProcessId = 2; Name = 'wslconfig.exe' }, [pscustomobject]@{ ProcessId = 3; Name = '' }) }
        Test-LaunchedFromWsl | Should -BeFalse
    }

    It '祖先を読めなければ真 (更新を見送る側に倒す)' {
        Mock Get-CurrentProcessAncestor { @() }
        Test-LaunchedFromWsl | Should -BeTrue
    }
}

Describe 'Get-WslUpdateStatus' {
    BeforeEach {
        Mock Get-WslPackageVersion { '3.0.3' }
        Mock Get-WslLatestVersion { '3.0.4' }
        Mock Test-LaunchedFromWsl { $false }
        Mock Get-WslDistros { @('Ubuntu-26.04') }
    }

    It '未導入なら not-installed (最新版を引かない)' {
        Mock Get-WslPackageVersion { '' }
        (Get-WslUpdateStatus -Repo 'microsoft/WSL').State | Should -Be 'not-installed'
        Should -Invoke Get-WslLatestVersion -Times 0 -Exactly
    }

    It '最新版が取れなければ unknown' {
        Mock Get-WslLatestVersion { '' }
        (Get-WslUpdateStatus -Repo 'microsoft/WSL').State | Should -Be 'unknown'
    }

    It '最新版以上なら up-to-date (起動中のディストロを調べない)' {
        foreach ($cur in '3.0.4', '3.0.10') {
            Mock Get-WslPackageVersion { $cur }
            (Get-WslUpdateStatus -Repo 'microsoft/WSL').State | Should -Be 'up-to-date'
        }
        Should -Invoke Get-WslDistros -Times 0 -Exactly
    }

    It '版は数値で比べる (3.0.10 は 3.0.9 より新しい)' {
        Mock Get-WslPackageVersion { '3.0.9' }
        Mock Get-WslLatestVersion { '3.0.10' }
        (Get-WslUpdateStatus -Repo 'microsoft/WSL').State | Should -Be 'available'
    }

    It 'WSL から起動されていれば skipped-from-wsl' {
        Mock Test-LaunchedFromWsl { $true }
        (Get-WslUpdateStatus -Repo 'microsoft/WSL').State | Should -Be 'skipped-from-wsl'
    }

    It '更新できれば available と版と起動中のディストロを返す' {
        $s = Get-WslUpdateStatus -Repo 'microsoft/WSL'
        $s.State | Should -Be 'available'
        $s.Current | Should -Be '3.0.3'
        $s.Latest | Should -Be '3.0.4'
        $s.Running | Should -Be @('Ubuntu-26.04')
        Should -Invoke Get-WslDistros -Times 1 -Exactly -ParameterFilter { $Running }
    }
}

Describe 'Update-WslPackage' {
    BeforeEach {
        Mock Test-LaunchedFromWsl { $false }
        Mock Out-Host { }
        Mock wsl.exe { $global:LASTEXITCODE = 0 }
        Mock Get-WslPackageVersion { '3.0.4' }
    }

    It 'WSL から起動されていれば実行しない' {
        Mock Test-LaunchedFromWsl { $true }
        Update-WslPackage -Latest '3.0.4' | Should -Be 'skipped-from-wsl'
        Should -Invoke wsl.exe -Times 0 -Exactly
    }

    It 'wsl --update で最新版になれば updated' {
        Update-WslPackage -Latest '3.0.4' | Should -Be 'updated'
        Should -Invoke wsl.exe -Times 1 -Exactly -ParameterFilter { $args -contains '--update' }
    }

    It 'wsl --update の間だけ WSL_UTF8=1 にし、終わったら元へ戻す' {
        $prev = $env:WSL_UTF8
        $env:WSL_UTF8 = 'keep-me'
        try {
            $script:SeenUtf8 = $null
            Mock wsl.exe { $script:SeenUtf8 = $env:WSL_UTF8; $global:LASTEXITCODE = 0 }
            Update-WslPackage -Latest '3.0.4' | Out-Null
            $script:SeenUtf8 | Should -Be '1'
            $env:WSL_UTF8 | Should -Be 'keep-me'
        } finally {
            $env:WSL_UTF8 = $prev
        }
    }

    It '成功しても版が上がらなければ not-yet-available' {
        Mock Get-WslPackageVersion { '3.0.3' }
        Update-WslPackage -Latest '3.0.4' | Should -Be 'not-yet-available'
    }

    It 'wsl --update が非 0 で終われば failed' {
        Mock wsl.exe { $global:LASTEXITCODE = 1 }
        Update-WslPackage -Latest '3.0.4' | Should -Be 'failed'
    }
}
