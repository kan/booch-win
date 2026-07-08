#requires -Version 5.1
# lib/scaffold.ps1 の雛形生成を検証する (Pester 5)。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $script:Root 'lib') 'scaffold.ps1')
}

Describe 'Get-BoochWinScaffoldKind' {
    It 'dotfiles-win を含む' {
        Get-BoochWinScaffoldKind -Root $script:Root | Should -Contain 'dotfiles-win'
    }
}

Describe 'New-BoochWinScaffold (dotfiles-win)' {
    BeforeEach {
        $script:Out = Join-Path $TestDrive ('gen_' + [guid]::NewGuid().ToString('N'))
    }

    It '期待するファイルを生成する' {
        $r = New-BoochWinScaffold -Kind 'dotfiles-win' -Path $script:Out -Root $script:Root
        $r.Created | Should -BeGreaterThan 0
        $r.Skipped | Should -Be 0
        foreach ($rel in @(
                'setup-win\dotfiles-win.ps1',
                'setup-win\dotfiles-win.config.ps1',
                'setup-win\dotfiles-win',
                'setup-win\dotfiles-win.cmd',
                'README.md',
                'CLAUDE.md',
                '.gitattributes'
            )) {
            Test-Path -LiteralPath (Join-Path $script:Out $rel) | Should -BeTrue -Because $rel
        }
    }

    It '生成した dotfiles-win.ps1 が構文エラー無くパースできる' {
        New-BoochWinScaffold -Kind 'dotfiles-win' -Path $script:Out -Root $script:Root | Out-Null
        $entry = Join-Path $script:Out 'setup-win\dotfiles-win.ps1'
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path -LiteralPath $entry).Path, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It '生成した config / 本体がトップレベルで parse できる（構文健全）' {
        New-BoochWinScaffold -Kind 'dotfiles-win' -Path $script:Out -Root $script:Root | Out-Null
        foreach ($rel in @('setup-win\dotfiles-win.ps1', 'setup-win\dotfiles-win.config.ps1')) {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                (Resolve-Path -LiteralPath (Join-Path $script:Out $rel)).Path, [ref]$null, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty -Because $rel
        }
    }

    It '再実行は既存を上書きせず skip する（冪等）' {
        New-BoochWinScaffold -Kind 'dotfiles-win' -Path $script:Out -Root $script:Root | Out-Null
        $r2 = New-BoochWinScaffold -Kind 'dotfiles-win' -Path $script:Out -Root $script:Root
        $r2.Created | Should -Be 0
        $r2.Skipped | Should -BeGreaterThan 0
    }

    It '-Force で既存を上書きする' {
        New-BoochWinScaffold -Kind 'dotfiles-win' -Path $script:Out -Root $script:Root | Out-Null
        $r2 = New-BoochWinScaffold -Kind 'dotfiles-win' -Path $script:Out -Force -Root $script:Root
        $r2.Created | Should -BeGreaterThan 0
    }

    It '相対 -Root でもフラットに生成する（templates 配下にネストしない）' {
        Push-Location $script:Root
        try {
            New-BoochWinScaffold -Kind 'dotfiles-win' -Path $script:Out -Root '.' | Out-Null
        } finally {
            Pop-Location
        }
        Test-Path -LiteralPath (Join-Path $script:Out 'setup-win\dotfiles-win.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Out 'templates') | Should -BeFalse
    }

    It '不明な kind は throw する' {
        { New-BoochWinScaffold -Kind 'no-such-kind' -Path $script:Out -Root $script:Root } |
            Should -Throw -ExpectedMessage '*no-such-kind*'
    }
}
