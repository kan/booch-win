#requires -Version 5.1
# lib/doctor.ps1 を検証する (Pester 5)。表示フレームそのものは副作用 (コンソール出力) なので、
# ここでは版の正規化と注記の組み立てだけを純粋に検証する。
# 「取得失敗」と「最新」を取り違えると、遅れているツールを最新だと誤認するので境界を固定する。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')    # Get-WslVhdxPath (Show-WslVhdxSize が使う。mock 対象)
    . (Join-Path $lib 'doctor.ps1')
}

Describe 'Get-VersionNumber' {
    It '装飾付きの --version 出力から数値だけを取り出す' {
        Get-VersionNumber 'gh version 2.96.0 (2026-07-02)' | Should -Be '2.96.0'
        Get-VersionNumber 'golang.org/x/tools/gopls v0.23.0' | Should -Be '0.23.0'
        Get-VersionNumber '2.1.215 (Claude Code)' | Should -Be '2.1.215'
        Get-VersionNumber 'codex-cli 0.144.6' | Should -Be '0.144.6'
        Get-VersionNumber 'v1.2' | Should -Be '1.2'
        Get-VersionNumber '1.24.11911.0' | Should -Be '1.24.11911.0'
    }

    It '数値が無ければ空文字 (installed 等)' {
        Get-VersionNumber 'installed' | Should -BeNullOrEmpty
        Get-VersionNumber '' | Should -BeNullOrEmpty
    }

    It '単独の整数は版とみなさない (区切りを含むものだけ拾う)' {
        Get-VersionNumber 'build 12345' | Should -BeNullOrEmpty
    }
}

Describe 'Get-VersionNote' {
    It '一致していれば注記なし' {
        Get-VersionNote -Current 'codex-cli 0.144.6' -Latest '0.144.6' | Should -BeNullOrEmpty
    }

    It '表記が違っても数値が同じなら最新とみなす' {
        Get-VersionNote -Current 'golang.org/x/tools/gopls v0.23.0' -Latest 'v0.23.0' | Should -BeNullOrEmpty
    }

    It '遅れていれば最新版を添える' {
        Get-VersionNote -Current '2.1.215 (Claude Code)' -Latest '2.2.0' | Should -Match 'update available: 2\.2\.0'
    }

    It '最新を取れなければ「最新」と見分けられるようにする' {
        # ここを空注記にすると、オフラインで回した回に遅れを見落とす。
        Get-VersionNote -Current '1.0.0' -Latest '' | Should -Match 'latest: unknown'
    }

    It '現在版を取れないときは比較せず最新だけ出す' {
        Get-VersionNote -Current 'installed' -Latest '3.1.4' | Should -Match 'latest: 3\.1\.4'
    }
}

Describe 'Show-DiskFree' {
    BeforeEach { Mock Write-Host {}; Mock Write-Status {} }

    It '閾値を下回れば WARN を返す (真偽値で消費側の集計に載せられる)' {
        Mock Get-PSDrive { [pscustomobject]@{ Free = 10GB; Used = 440GB } }
        Show-DiskFree -Drive C -WarnGB 20 | Should -BeTrue
        Should -Invoke Write-Status -ParameterFilter { $Status -eq 'WARN' } -Times 1
    }

    It '閾値を上回れば OK' {
        Mock Get-PSDrive { [pscustomobject]@{ Free = 100GB; Used = 350GB } }
        Show-DiskFree -Drive C -WarnGB 20 | Should -BeFalse
        Should -Invoke Write-Status -ParameterFilter { $Status -eq 'OK' } -Times 1
    }

    It '閾値 0 なら判定せず表示だけ' {
        Mock Get-PSDrive { [pscustomobject]@{ Free = 1GB; Used = 449GB } }
        Show-DiskFree -Drive C -WarnGB 0 | Should -BeFalse
    }

    It '取得できないドライブは SKIP (診断自体は落とさない)' {
        Mock Get-PSDrive { $null }
        Show-DiskFree -Drive Z -WarnGB 20 | Should -BeFalse
        Should -Invoke Write-Status -ParameterFilter { $Status -eq 'SKIP' } -Times 1
    }
}

Describe 'Show-WslVhdxSize' {
    BeforeEach { Mock Write-Host {}; Mock Write-Status {} }

    It 'ディストロが無ければ SKIP' {
        Mock Get-WslVhdxPath { @() }
        { Show-WslVhdxSize } | Should -Not -Throw
        Should -Invoke Write-Status -ParameterFilter { $Status -eq 'SKIP' } -Times 1
    }

    It '各ディストロの vhdx サイズを 1 行ずつ出す' {
        $f = Join-Path $TestDrive 'ext4.vhdx'
        Set-Content -LiteralPath $f -Value 'x'
        Mock Get-WslVhdxPath { @([pscustomobject]@{ Name = 'Ubuntu'; Vhdx = $f }) }
        Show-WslVhdxSize
        Should -Invoke Write-Status -ParameterFilter { $Label -match 'Ubuntu' } -Times 1
    }
}
