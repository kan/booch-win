#requires -Version 5.1
# lib/git.ps1 の Update-BoochWinGitRepo / Invoke-BoochWinGitPullRepos を検証する (Pester 5)。
# 実 git は叩かず、seam (Get-BoochWinGitBranch / Test-BoochWinGitDirty / Get-BoochWinGitHead /
# Invoke-BoochWinGitFfPull) を Mock して分岐だけを純粋に見る。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'git.ps1')

    # <dir>/.git を持つ「repo に見えるディレクトリ」を作る。
    function New-FakeRepo {
        param([string]$Base, [string]$Name)
        $path = Join-Path $Base $Name
        New-Item -ItemType Directory -Path (Join-Path $path '.git') -Force | Out-Null
        return $path
    }
}

Describe 'Update-BoochWinGitRepo' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Status {}; Mock Write-Info {}
        $script:Base = Join-Path $TestDrive ('g_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Base -Force | Out-Null
        $script:Repo = New-FakeRepo -Base $script:Base -Name 'sample'
    }

    It '.git が無いディレクトリは notrepo を返し pull しない' {
        Mock Invoke-BoochWinGitFfPull { [pscustomobject]@{ Success = $true; Output = '' } }
        $plain = Join-Path $script:Base 'plain'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        Update-BoochWinGitRepo -Path $plain | Should -Be 'notrepo'
        Should -Invoke Invoke-BoochWinGitFfPull -Times 0
    }

    It '許可外ブランチは skip-branch を返し pull しない' {
        Mock Get-BoochWinGitBranch { 'feature/x' }
        Mock Test-BoochWinGitDirty { $false }
        Mock Invoke-BoochWinGitFfPull { [pscustomobject]@{ Success = $true; Output = '' } }
        Update-BoochWinGitRepo -Path $script:Repo | Should -Be 'skip-branch'
        Should -Invoke Invoke-BoochWinGitFfPull -Times 0
    }

    It 'detached HEAD (ブランチ取得不可) も skip-branch になる' {
        Mock Get-BoochWinGitBranch { '' }
        Mock Invoke-BoochWinGitFfPull { [pscustomobject]@{ Success = $true; Output = '' } }
        Update-BoochWinGitRepo -Path $script:Repo | Should -Be 'skip-branch'
        Should -Invoke Invoke-BoochWinGitFfPull -Times 0
    }

    It '作業ツリーが汚れていれば dirty を返し pull しない' {
        Mock Get-BoochWinGitBranch { 'main' }
        Mock Test-BoochWinGitDirty { $true }
        Mock Invoke-BoochWinGitFfPull { [pscustomobject]@{ Success = $true; Output = '' } }
        Update-BoochWinGitRepo -Path $script:Repo | Should -Be 'dirty'
        Should -Invoke Invoke-BoochWinGitFfPull -Times 0
    }

    It 'pull 前後で HEAD が変わらなければ uptodate' {
        Mock Get-BoochWinGitBranch { 'main' }
        Mock Test-BoochWinGitDirty { $false }
        Mock Get-BoochWinGitHead { 'aaaa111' }
        Mock Invoke-BoochWinGitFfPull { [pscustomobject]@{ Success = $true; Output = 'Already up to date.' } }
        Update-BoochWinGitRepo -Path $script:Repo | Should -Be 'uptodate'
    }

    It 'pull 前後で HEAD が変われば updated (メッセージ文言に依存しない)' {
        Mock Get-BoochWinGitBranch { 'main' }
        Mock Test-BoochWinGitDirty { $false }
        # 1 回目 = pull 前、2 回目 = pull 後。日本語 locale の出力でも判定が崩れないこと。
        $script:heads = @('aaaa111', 'bbbb222')
        Mock Get-BoochWinGitHead { $script:heads[0] } -ParameterFilter { $true }
        Mock Invoke-BoochWinGitFfPull {
            $script:heads = @('bbbb222', 'bbbb222')
            [pscustomobject]@{ Success = $true; Output = '既に最新です。' }
        }
        Update-BoochWinGitRepo -Path $script:Repo | Should -Be 'updated'
    }

    It 'pull が失敗すれば failed' {
        Mock Get-BoochWinGitBranch { 'main' }
        Mock Test-BoochWinGitDirty { $false }
        Mock Get-BoochWinGitHead { 'aaaa111' }
        Mock Invoke-BoochWinGitFfPull { [pscustomobject]@{ Success = $false; Output = "hint: ...`nfatal: Not possible to fast-forward" } }
        Update-BoochWinGitRepo -Path $script:Repo | Should -Be 'failed'
    }

    It 'master / develop も既定の許可ブランチに含む' {
        Mock Test-BoochWinGitDirty { $false }
        Mock Get-BoochWinGitHead { 'aaaa111' }
        Mock Invoke-BoochWinGitFfPull { [pscustomobject]@{ Success = $true; Output = '' } }
        foreach ($b in @('master', 'main', 'develop')) {
            Mock Get-BoochWinGitBranch { $b }.GetNewClosure()
            Update-BoochWinGitRepo -Path $script:Repo | Should -Be 'uptodate'
        }
    }
}

Describe 'Invoke-BoochWinGitPullRepos' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Status {}; Mock Write-Info {}
        Mock Test-Cmd { $true }
        Mock Update-BoochWinGitRepo { 'uptodate' }
        $script:Base = Join-Path $TestDrive ('p_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Base -Force | Out-Null
    }

    It '実在する repo だけを対象にし、clone していない名前は黙って飛ばす' {
        New-FakeRepo -Base $script:Base -Name 'alpha' | Out-Null
        Invoke-BoochWinGitPullRepos -BaseDir $script:Base -Repos @('alpha', 'missing')
        Should -Invoke Update-BoochWinGitRepo -Times 1
        Should -Invoke Update-BoochWinGitRepo -Times 1 -ParameterFilter { $Label -eq 'alpha' }
    }

    It '.git を持たないディレクトリは対象にしない' {
        New-Item -ItemType Directory -Path (Join-Path $script:Base 'plain') -Force | Out-Null
        Invoke-BoochWinGitPullRepos -BaseDir $script:Base -Repos @('plain')
        Should -Invoke Update-BoochWinGitRepo -Times 0
    }

    It '対象が 1 つも無ければその旨を出して終わる' {
        Invoke-BoochWinGitPullRepos -BaseDir $script:Base -Repos @('missing')
        Should -Invoke Write-Info -Times 1
        Should -Invoke Update-BoochWinGitRepo -Times 0
    }

    It 'git が無ければ何もしない' {
        Mock Test-Cmd { $false }
        New-FakeRepo -Base $script:Base -Name 'alpha' | Out-Null
        Invoke-BoochWinGitPullRepos -BaseDir $script:Base -Repos @('alpha')
        Should -Invoke Update-BoochWinGitRepo -Times 0
    }

    It '重複した repo 名は 1 回だけ処理する' {
        New-FakeRepo -Base $script:Base -Name 'alpha' | Out-Null
        Invoke-BoochWinGitPullRepos -BaseDir $script:Base -Repos @('alpha', 'alpha')
        Should -Invoke Update-BoochWinGitRepo -Times 1
    }

    It '絶対パスで指定した repo も対象にする' {
        $other = Join-Path $TestDrive ('o_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        $abs = New-FakeRepo -Base $other -Name 'beta'
        Invoke-BoochWinGitPullRepos -BaseDir $script:Base -Repos @($abs)
        Should -Invoke Update-BoochWinGitRepo -Times 1 -ParameterFilter { $Label -eq 'beta' }
    }

    It '許可ブランチをそのまま Update-BoochWinGitRepo へ渡す' {
        New-FakeRepo -Base $script:Base -Name 'alpha' | Out-Null
        Invoke-BoochWinGitPullRepos -BaseDir $script:Base -Repos @('alpha') -Branches @('trunk')
        Should -Invoke Update-BoochWinGitRepo -Times 1 -ParameterFilter { $Branches -contains 'trunk' }
    }
}
