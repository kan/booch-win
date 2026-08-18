#requires -Version 5.1
# lib/winget.ps1 を検証する (Pester 5)。winget.exe を実際に叩く部分 (Invoke-WingetRead) は
# 副作用の塊なので seam として mock し、その戻り値をどう解釈するか — 終了コードの分類
# (Test-WingetUpgradeNoop)、3 値の導入判定 (Get-WingetInstallState)、判定不能時の
# skip (Install-WingetPackages) — を純粋に検証する。
# ここを取り違えると「更新の失敗を毎回無視する」か「最新のたびに警告を出す」、あるいは
# 「応答が返らない winget を無限に待つ」のいずれかになるため、境界を明示的に固定しておく。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')    # Get-EffectiveTimeout (Get-WingetReadTimeout が使う)
    . (Join-Path $lib 'winget.ps1')
}

Describe 'Test-WingetUpgradeNoop' {
    It '0 は成功 (実際に更新した)' {
        Test-WingetUpgradeNoop 0 | Should -BeTrue
    }

    It '0x8A15002B (適用できる更新が無い) は失敗としない' {
        # 最新のパッケージへ upgrade をかけると毎回これが返る。
        Test-WingetUpgradeNoop -1978335189 | Should -BeTrue
    }

    It 'ID を解決できない等の別コードは失敗として扱う' {
        # 0x8A150014: 条件に一致するパッケージが見つからない。追跡 ID が winget ソースと
        # 相関できていない状態なので、隠さず可視化したい。
        Test-WingetUpgradeNoop -1978335212 | Should -BeFalse
    }

    It '未知の非 0 は失敗として扱う' {
        Test-WingetUpgradeNoop 1 | Should -BeFalse
        Test-WingetUpgradeNoop -1 | Should -BeFalse
    }
}

Describe 'Get-WingetReadTimeout' {
    AfterEach {
        Remove-Variable -Name WingetReadTimeoutSec -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name DisableTimeout       -Scope Script -ErrorAction SilentlyContinue
    }

    It 'エントリ側が何も定義していなければ既定の 60 秒' {
        Get-WingetReadTimeout | Should -Be 60
    }

    It 'エントリ側の $Script:WingetReadTimeoutSec を優先する' {
        $Script:WingetReadTimeoutSec = 5
        Get-WingetReadTimeout | Should -Be 5
    }

    It '--no-timeout ($Script:DisableTimeout) では 0 (無制限) を返す' {
        $Script:WingetReadTimeoutSec = 5
        $Script:DisableTimeout = $true
        Get-WingetReadTimeout | Should -Be 0
    }
}

Describe 'Invoke-WingetRead (実プロセス)' {
    # ここだけは seam を挟まず実プロセスを起動する。終了コードを取れるかどうかは
    # Start-Process の使い方そのものに依存していて、Invoke-WingetRead を mock した
    # 契約テストでは絶対に捕まらないため (実際、リダイレクト併用で ExitCode が $null に
    # なり、[int] キャストで 0 = 成功へ化ける回帰を実機まで検出できなかった)。
    # winget.exe は CI にも開発機にも無いことがあるので cmd.exe で代用する。

    It 'リダイレクトを併用しても非 0 の終了コードを取り落とさない' {
        $r = Invoke-WingetRead -FilePath 'cmd.exe' -WingetArgs @('/c', 'exit 3')
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be 3
    }

    It '成功 (exit 0) と失敗を取り違えない' {
        $r = Invoke-WingetRead -FilePath 'cmd.exe' -WingetArgs @('/c', 'exit 0')
        $r.ExitCode | Should -Be 0
    }

    It '上限を超えたら TimedOut で、終了コードは名乗らない' {
        $r = Invoke-WingetRead -FilePath 'cmd.exe' -WingetArgs @('/c', 'ping -n 20 127.0.0.1') -TimeoutSec 1
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -BeNullOrEmpty
    }

    It '起動できなければ ExitCode は $null (0 へ丸めない)' {
        $r = Invoke-WingetRead -FilePath 'booch-win-no-such-exe.exe' -WingetArgs @('--version')
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -BeNullOrEmpty
    }
}

Describe 'Get-WingetInstallState' {
    It 'exit 0 は Installed' {
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = 0 } }
        Get-WingetInstallState 'Foo.Bar' | Should -Be 'Installed'
    }

    It '非 0 は NotInstalled' {
        # NO_APPLICATIONS_FOUND。未導入の通常経路。
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = -1978335212 } }
        Get-WingetInstallState 'Foo.Bar' | Should -Be 'NotInstalled'
    }

    It 'タイムアウトは Unknown (未導入へ丸めない)' {
        Mock Invoke-WingetRead { @{ TimedOut = $true; ExitCode = $null } }
        Get-WingetInstallState 'Foo.Bar' | Should -Be 'Unknown'
    }

    It '起動失敗 (winget.exe が無い) も Unknown' {
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = $null } }
        Get-WingetInstallState 'Foo.Bar' | Should -Be 'Unknown'
    }

    It '省略時は Get-WingetReadTimeout の値を渡す' {
        Mock Get-WingetReadTimeout { 42 }
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = 0 } }
        Get-WingetInstallState 'Foo.Bar' | Out-Null
        Should -Invoke Invoke-WingetRead -Times 1 -ParameterFilter { $TimeoutSec -eq 42 }
    }

    It '明示した TimeoutSec はそのまま使う' {
        Mock Get-WingetReadTimeout { 42 }
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = 0 } }
        Get-WingetInstallState 'Foo.Bar' -TimeoutSec 7 | Out-Null
        Should -Invoke Invoke-WingetRead -Times 1 -ParameterFilter { $TimeoutSec -eq 7 }
    }
}

Describe 'Get-WingetInstalledIds' {
    It 'export した JSON から PackageIdentifier を集める' {
        Mock Invoke-WingetRead {
            # 実物と同じく -o の次の引数が出力先。mock 側でそこへ JSON を置く。
            $out = $WingetArgs[[array]::IndexOf($WingetArgs, '-o') + 1]
            $json = '{"Sources":[{"Packages":[{"PackageIdentifier":"Foo.Bar"},{"PackageIdentifier":"Baz.Qux"}]}]}'
            Set-Content -LiteralPath $out -Value $json -Encoding UTF8
            @{ TimedOut = $false; ExitCode = 0 }
        }
        $ids = Get-WingetInstalledIds
        $ids | Should -Be @('Foo.Bar', 'Baz.Qux')
    }

    It 'タイムアウトなら空配列 (途中まで書かれた JSON を読まない)' {
        Mock Invoke-WingetRead {
            $out = $WingetArgs[[array]::IndexOf($WingetArgs, '-o') + 1]
            Set-Content -LiteralPath $out -Value '{"Sources":[{"Packages":[{"PackageIdentifier":"Foo.Bar"}' -Encoding UTF8
            @{ TimedOut = $true; ExitCode = $null }
        }
        @(Get-WingetInstalledIds).Count | Should -Be 0
    }

    It '起動失敗なら空配列' {
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = $null } }
        @(Get-WingetInstalledIds).Count | Should -Be 0
    }
}

Describe 'Install-WingetPackages' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}; Mock Write-Fail {}
        Mock Invoke-Winget { 0 }
    }

    It '導入済みなら upgrade を呼ぶ' {
        Mock Get-WingetInstallState { 'Installed' }
        Install-WingetPackages -Packages @(@{ Id = 'Foo.Bar'; Cmd = 'foo' })
        Should -Invoke Invoke-Winget -Times 1 -ParameterFilter { $WingetArgs[0] -eq 'upgrade' }
    }

    It '未導入なら install を呼ぶ' {
        Mock Get-WingetInstallState { 'NotInstalled' }
        Install-WingetPackages -Packages @(@{ Id = 'Foo.Bar'; Cmd = 'foo' })
        Should -Invoke Invoke-Winget -Times 1 -ParameterFilter { $WingetArgs[0] -eq 'install' }
    }

    It '判定不能なら winget を一切叩かず警告して次へ進む' {
        Mock Get-WingetInstallState { if ($Id -eq 'Slow.One') { 'Unknown' } else { 'NotInstalled' } }
        Install-WingetPackages -Packages @(
            @{ Id = 'Slow.One'; Cmd = 'slow' },
            @{ Id = 'Foo.Bar';  Cmd = 'foo' }
        )
        # skip したパッケージでは install も upgrade も走らない (= 呼び出しは後続の 1 回だけ)。
        Should -Invoke Invoke-Winget -Times 1
        Should -Invoke Invoke-Winget -Times 1 -ParameterFilter { $WingetArgs -contains 'Foo.Bar' }
        # skip は黙って起きない (次回の実行で拾う旨をログに残す)。
        Should -Invoke Write-Warn -Times 1 -ParameterFilter { $Msg -like '*Slow.One*' }
    }
}
