#requires -Version 5.1
# lib/textlint.ps1 を検証する (Pester 5)。npm 本体は叩かず、関数でシャドウして
# 渡された引数だけを記録する (PowerShell のコマンド解決は Function > Native)。
#
# 見たいのは「版をどこまで追従させるか」の分岐だけ。src に package-lock.json が
# あるかどうかで install のみ / install + update が切り替わる。ここを取り違えると
# 「意図した版固定を勝手に動かす」か「レンジ内の新版へ永久に上がらない」の
# どちらかになる (後者を実際に踏んだ: textlint が ^15.7.1 のまま 15.8.0 へ
# 上がらず doctor が毎回更新を促し続けた)。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'textlint.ps1')
}

Describe 'Install-Textlint' {
    BeforeEach {
        $script:Src  = Join-Path $TestDrive ('s_' + [guid]::NewGuid().ToString('N'))
        $script:Dest = Join-Path $TestDrive ('d_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Src -Force | Out-Null
        # npm をシャドウして呼び出しを記録する。Install-Textlint 内の Test-Cmd 'npm' も
        # この関数で満たされる (Get-Command が引ける)。
        $global:NpmCalls = @()
        function global:npm { $global:NpmCalls += ($args -join ' ') }
    }

    AfterEach {
        Remove-Item Function:global:npm -ErrorAction SilentlyContinue
        Remove-Variable -Name NpmCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'src に lockfile が無ければ install に続けて update する' {
        # dest の lockfile は初回 install の副産物にすぎず、npm install はそれが
        # レンジを満たす限り古い版を保持する。update でレンジ内最新へ追従させる。
        Set-Content -Path (Join-Path $script:Src 'package.json') -Value '{"name":"x"}'
        Install-Textlint -SrcDir $script:Src -DestDir $script:Dest
        $global:NpmCalls | Should -Contain 'install --no-audit --no-fund'
        $global:NpmCalls | Should -Contain 'update --no-audit --no-fund'
    }

    It 'src に lockfile があれば固定を尊重して update しない' {
        Set-Content -Path (Join-Path $script:Src 'package.json') -Value '{"name":"x"}'
        Set-Content -Path (Join-Path $script:Src 'package-lock.json') -Value '{}'
        Install-Textlint -SrcDir $script:Src -DestDir $script:Dest
        $global:NpmCalls | Should -Contain 'install --no-audit --no-fund'
        $global:NpmCalls | Should -Not -Contain 'update --no-audit --no-fund'
        (Test-Path (Join-Path $script:Dest 'package-lock.json')) | Should -BeTrue
    }

    It 'package.json が無ければ npm を叩かずスキップする' {
        Install-Textlint -SrcDir $script:Src -DestDir $script:Dest
        $global:NpmCalls.Count | Should -Be 0
    }
}
