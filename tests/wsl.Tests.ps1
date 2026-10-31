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

# .wslconfig の推奨値の計算、行の組み立て、状態の判定。実際の %USERPROFILE%\.wslconfig には触らない。
Describe '.wslconfig' {
    BeforeAll {
        # 計算を固定の入力で確かめるための割合 (利用側の config の値を変えてもテストは変えない)。
        $script:Policy = @{ ReserveMinGB = 6; ReserveRatio = 0.3; SwapMaxGB = 16 }
    }
    BeforeEach {
        $script:CfgPath = Join-Path ([IO.Path]::GetTempPath()) ('wslconfig-test-' + [guid]::NewGuid().ToString('N'))
    }
    AfterEach { Remove-Item -LiteralPath $script:CfgPath -ErrorAction SilentlyContinue }

    Context 'Get-WslConfigRecommendation' {
        It '32GB 機（実測 31.6GB）は memory=21GB / swap=11GB' {
            $r = Get-WslConfigRecommendation -TotalGB 31.6 -Policy $script:Policy
            $r.MemoryGB | Should -Be 21
            $r.SwapGB | Should -Be 11
        }
        It '16GB 機は Windows に最低 6GB を残す' {
            $r = Get-WslConfigRecommendation -TotalGB 16 -Policy $script:Policy
            $r.MemoryGB | Should -Be 10
            $r.SwapGB | Should -Be 5
        }
        It '大きい機では swap が SwapMaxGB で頭打ちになる' {
            $r = Get-WslConfigRecommendation -TotalGB 64 -Policy $script:Policy
            $r.MemoryGB | Should -Be 44
            $r.SwapGB | Should -Be 16
        }
        It '32GB 機と 16GB 機は作ると増えるので Beneficial' {
            (Get-WslConfigRecommendation -TotalGB 31.6 -Policy $script:Policy).Beneficial | Should -BeTrue
            (Get-WslConfigRecommendation -TotalGB 16 -Policy $script:Policy).Beneficial | Should -BeTrue
        }
        It '8GB 機は既定 (半分) より減るので Beneficial ではない' {
            (Get-WslConfigRecommendation -TotalGB 7.8 -Policy $script:Policy).Beneficial | Should -BeFalse
        }
        It '下限 2GB を当てても、Windows に残す量を割り込む小さい PC は Beneficial ではない' {
            (Get-WslConfigRecommendation -TotalGB 3 -Policy $script:Policy).Beneficial | Should -BeFalse
        }
        It 'Policy のキーが欠けていれば throw する' {
            { Get-WslConfigRecommendation -TotalGB 16 -Policy @{ ReserveMinGB = 6; ReserveRatio = 0.3 } } | Should -Throw '*SwapMaxGB*'
        }
    }

    Context 'Read-WslConfigWsl2' {
        It '[wsl2] 節のキーだけを拾う' {
            Set-Content -LiteralPath $script:CfgPath -Value @('[experimental]', 'swap=1GB', '[WSL2]', 'Memory = 21GB')
            $c = Read-WslConfigWsl2 -Path $script:CfgPath
            $c.HasSection | Should -BeTrue
            $c.Values['memory'] | Should -Be '21GB'
            $c.Values.ContainsKey('swap') | Should -BeFalse
        }
        It '[wsl2] 節が無ければ HasSection が false' {
            Set-Content -LiteralPath $script:CfgPath -Value @('memory=21GB')
            (Read-WslConfigWsl2 -Path $script:CfgPath).HasSection | Should -BeFalse
        }
    }

    Context 'Get-WslConfigLines' {
        It '[wsl2] 節に memory と swap を書き、ASCII だけで組む' {
            $r = Get-WslConfigRecommendation -TotalGB 31.6 -Policy $script:Policy
            $lines = Get-WslConfigLines -Recommendation $r
            $lines | Should -Contain '[wsl2]'
            $lines | Should -Contain 'memory=21GB'
            $lines | Should -Contain 'swap=11GB'
            ($lines -join "`n") | Should -Not -Match '[^\x00-\x7F]'
        }
        It '-CreatedBy を先頭のコメントに入れる' {
            $r = Get-WslConfigRecommendation -TotalGB 31.6 -Policy $script:Policy
            (Get-WslConfigLines -Recommendation $r -CreatedBy 'my-setup')[0] | Should -Match '^# Created by my-setup '
        }
    }

    Context 'Get-WslConfigStatus' {
        It 'ファイルが無く、作ると増える PC なら missing と推奨値を返す' {
            Mock Get-PhysicalMemoryGB { 31.6 }
            $s = Get-WslConfigStatus -Policy $script:Policy -Path $script:CfgPath
            $s.State | Should -Be 'missing'
            $s.Recommendation.MemoryGB | Should -Be 21
        }
        It 'ファイルが無く、物理メモリを取れなければ missing で推奨値は $null' {
            Mock Get-PhysicalMemoryGB { $null }
            $s = Get-WslConfigStatus -Policy $script:Policy -Path $script:CfgPath
            $s.State | Should -Be 'missing'
            $s.Recommendation | Should -BeNullOrEmpty
        }
        It 'ファイルが無く、作っても増えない PC なら not-needed' {
            Mock Get-PhysicalMemoryGB { 7.8 }
            (Get-WslConfigStatus -Policy $script:Policy -Path $script:CfgPath).State | Should -Be 'not-needed'
        }
        It '[wsl2] 節が無ければ no-section' {
            Set-Content -LiteralPath $script:CfgPath -Value @('memory=21GB')
            (Get-WslConfigStatus -Policy $script:Policy -Path $script:CfgPath).State | Should -Be 'no-section'
        }
        It '[wsl2] 節があれば ok と memory / swap を返す (書かれていないキーは空)' {
            Set-Content -LiteralPath $script:CfgPath -Value @('[wsl2]', 'memory=21GB')
            $s = Get-WslConfigStatus -Policy $script:Policy -Path $script:CfgPath
            $s.State | Should -Be 'ok'
            $s.Memory | Should -Be '21GB'
            $s.Swap | Should -Be ''
        }
    }
}
