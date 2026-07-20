#requires -Version 5.1
# lib/font.ps1 を検証する (Pester 5)。ダウンロード・レジストリ登録は副作用なので、
# ここでは版の記録まわり (どこに書くか / 読めるか) だけを純粋に検証する。
# 記録を読み違えると「最新なのに毎回 30MB 引き直す」か「古いまま更新されない」になる。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'font.ps1')
}

Describe 'フォントの版の記録' {
    BeforeEach {
        # 実環境の %LOCALAPPDATA% を触らないよう差し替える。
        $script:PrevLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $TestDrive ('lad_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts') | Out-Null
    }
    AfterEach { $env:LOCALAPPDATA = $script:PrevLocalAppData }

    It '記録先はフォントディレクトリ配下で、ファミリ名の空白は安全な文字へ落とす' {
        $p = Get-FontVersionStampPath -Family 'PlemolJP Console NF'
        $p | Should -BeLike (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts\*')
        (Split-Path $p -Leaf) | Should -Be '.booch-win-PlemolJP-Console-NF.version'
    }

    It '記録が無ければ空文字 (この仕組みより前に入れた分)' {
        Get-FontInstalledVersion -Family 'PlemolJP Console NF' | Should -BeNullOrEmpty
    }

    It '記録したタグを読み戻せる (末尾の改行は落とす)' {
        Set-Content -LiteralPath (Get-FontVersionStampPath -Family 'PlemolJP Console NF') -Value "v3.0.0`n"
        Get-FontInstalledVersion -Family 'PlemolJP Console NF' | Should -Be 'v3.0.0'
    }

    It 'ファミリごとに独立して記録する' {
        Set-Content -LiteralPath (Get-FontVersionStampPath -Family 'A Font') -Value 'v1.0.0'
        Get-FontInstalledVersion -Family 'A Font' | Should -Be 'v1.0.0'
        Get-FontInstalledVersion -Family 'B Font' | Should -BeNullOrEmpty
    }
}

Describe 'Get-FontDestFileName (上書きを避ける配置名)' {
    It '拡張子の前にリリースタグを挟む' {
        # 同名で上書きすると、動作中のアプリが掴んでいる ttf は必ず書き込みに失敗する。
        Get-FontDestFileName -SourceName 'PlemolJPConsoleNF-Regular.ttf' -Version 'v3.0.0' |
            Should -Be 'PlemolJPConsoleNF-Regular_v3.0.0.ttf'
    }

    It 'ファイル名に使えない文字はタグから落とす' {
        Get-FontDestFileName -SourceName 'A-Regular.ttf' -Version 'release/1.0 beta' |
            Should -Be 'A-Regular_release-1.0-beta.ttf'
    }

    It 'タグが無ければ元の名前のまま' {
        Get-FontDestFileName -SourceName 'A-Regular.ttf' -Version '' | Should -Be 'A-Regular.ttf'
        Get-FontDestFileName -SourceName 'A-Regular.ttf' | Should -Be 'A-Regular.ttf'
    }

    It '同じ版なら同じ名前になる (再実行で増殖しない)' {
        $a = Get-FontDestFileName -SourceName 'A-Regular.ttf' -Version 'v1.2.3'
        $b = Get-FontDestFileName -SourceName 'A-Regular.ttf' -Version 'v1.2.3'
        $a | Should -Be $b
    }
}
