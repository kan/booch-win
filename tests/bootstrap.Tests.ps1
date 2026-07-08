#requires -Version 5.1
# lib/bootstrap.ps1 のルート解決とロード対象一覧を検証する (Pester 5)。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $script:Root 'lib') 'bootstrap.ps1')

    # env BOOCH_WIN_ROOT はプロセス共有なので退避し、各テストの前にクリアする。
    $script:OrigEnv = $env:BOOCH_WIN_ROOT

    function New-FakeRoot {
        param([string]$Path)
        $lib = Join-Path $Path 'lib'
        New-Item -ItemType Directory -Path $lib -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $lib 'common.ps1') -Value '# fake' -Encoding UTF8
        return $Path
    }
}

AfterAll {
    if ($null -ne $script:OrigEnv) { $env:BOOCH_WIN_ROOT = $script:OrigEnv }
    else { Remove-Item Env:BOOCH_WIN_ROOT -ErrorAction SilentlyContinue }
}

Describe 'Resolve-BoochWinRoot' {
    BeforeEach { Remove-Item Env:BOOCH_WIN_ROOT -ErrorAction SilentlyContinue }

    It 'BOOCH_WIN_ROOT が有効ならそれを返す' {
        $env:BOOCH_WIN_ROOT = New-FakeRoot (Join-Path $TestDrive 'envroot')
        Resolve-BoochWinRoot -DotfilesDir (Join-Path $TestDrive 'nowhere') |
            Should -Be $env:BOOCH_WIN_ROOT
    }
    It 'BOOCH_WIN_ROOT が無効なら throw する' {
        $env:BOOCH_WIN_ROOT = Join-Path $TestDrive 'broken-env'  # lib/common.ps1 なし
        { Resolve-BoochWinRoot -DotfilesDir $TestDrive } | Should -Throw -ExpectedMessage '*BOOCH_WIN_ROOT*'
    }
    It 'vendor/booch-win があれば返す' {
        $dot = Join-Path $TestDrive 'd1'
        New-FakeRoot (Join-Path $dot 'vendor\booch-win') | Out-Null
        Resolve-BoochWinRoot -DotfilesDir $dot | Should -Be (Join-Path $dot 'vendor\booch-win')
    }
    It 'vendor が無く sibling ../booch-win があれば返す' {
        $base = Join-Path $TestDrive 'sibcase'
        $dot = Join-Path $base 'dotfiles'
        New-Item -ItemType Directory -Path $dot -Force | Out-Null
        New-FakeRoot (Join-Path $base 'booch-win') | Out-Null
        Resolve-BoochWinRoot -DotfilesDir $dot | Should -Be (Join-Path $base 'booch-win')
    }
    It 'legacy SetupWinDir に lib があれば返す' {
        $legacy = New-FakeRoot (Join-Path $TestDrive 'legacy')
        Resolve-BoochWinRoot -DotfilesDir (Join-Path $TestDrive 'nope') -SetupWinDir $legacy |
            Should -Be $legacy
    }
    It 'どこにも無ければ $null を返す' {
        Resolve-BoochWinRoot -DotfilesDir (Join-Path $TestDrive 'empty-dot') | Should -BeNullOrEmpty
    }
    It '親の無い DotfilesDir (単一セグメントの相対パス) でも throw せず $null' {
        # Split-Path -Parent 'dotfiles' は '' を返す。sibling 判定を飛ばして落ちないこと。
        { Resolve-BoochWinRoot -DotfilesDir 'dotfiles' } | Should -Not -Throw
        Resolve-BoochWinRoot -DotfilesDir 'dotfiles' | Should -BeNullOrEmpty
    }
    It 'env が vendor より優先される' {
        $env:BOOCH_WIN_ROOT = New-FakeRoot (Join-Path $TestDrive 'winner')
        $dot = Join-Path $TestDrive 'd2'
        New-FakeRoot (Join-Path $dot 'vendor\booch-win') | Out-Null
        Resolve-BoochWinRoot -DotfilesDir $dot | Should -Be $env:BOOCH_WIN_ROOT
    }
}

Describe 'Get-BoochWinLibFile' {
    # 添字アクセスするので @() で配列化して受ける (単数返却のスカラー展開対策)。
    BeforeAll { $script:Files = @(Get-BoochWinLibFile -Root $script:Root) }

    It 'bootstrap.ps1 と apidoc.ps1 を除外する' {
        ($script:Files | Where-Object { $_ -match 'bootstrap\.ps1$' }) | Should -BeNullOrEmpty
        ($script:Files | Where-Object { $_ -match 'apidoc\.ps1$' })    | Should -BeNullOrEmpty
    }
    It 'common.ps1 を先頭にする' {
        (Split-Path $script:Files[0] -Leaf) | Should -Be 'common.ps1'
    }
    It '主要 lib を含む' {
        ($script:Files | Where-Object { $_ -match 'winget\.ps1$' }) | Should -Not -BeNullOrEmpty
        ($script:Files | Where-Object { $_ -match 'sync\.ps1$' })   | Should -Not -BeNullOrEmpty
        ($script:Files | Where-Object { $_ -match 'system\.ps1$' }) | Should -Not -BeNullOrEmpty
    }
    It 'すべて実在する .ps1 のフルパス' {
        foreach ($f in $script:Files) {
            $f | Should -Match '\.ps1$'
            Test-Path -LiteralPath $f | Should -BeTrue
        }
    }
    It 'lib が無いルートでは空を返す' {
        Get-BoochWinLibFile -Root (Join-Path $TestDrive 'no-lib-here') | Should -BeNullOrEmpty
    }
}
