#requires -Version 5.1
# lib/sync.ps1 の Invoke-BoochWinSync オーケストレーションを検証する (Pester 5)。
# エンジン関数 (Deploy-Pair/Import-Pair/Test-PairInSync) と Read-Host をモックし、
# 分岐 (未配備/一致/差分→r/e/s/repo 欠落) の挙動を確認する。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'sync.ps1')

    function New-Pair {
        param([string]$Dot, [string]$Repo, [string]$Dest, [string]$RepoContent = 'repo', [switch]$NoRepoFile)
        if (-not $NoRepoFile) {
            $rf = Join-Path $Dot $Repo
            New-Item -ItemType Directory -Path (Split-Path $rf -Parent) -Force | Out-Null
            Set-Content -LiteralPath $rf -Value $RepoContent -Encoding UTF8
        }
        return @{ Repo = $Repo; Dest = $Dest }
    }
}

Describe 'Transform エンジン (GitGpgProgram)' {
    It 'Set-GitGpgProgram は program 行の値を差し替え、タブを保持する' {
        $content = "[gpg `"ssh`"]`n`tprogram = C:\\old\\op-ssh-sign.exe`n`tformat = ssh`n"
        $out = Set-GitGpgProgram $content 'D:\\new\\op-ssh-sign.exe'
        $out | Should -Match "`tprogram = D:\\\\new\\\\op-ssh-sign\.exe"
        $out | Should -Match "`tformat = ssh"       # 他の行は不変
    }
    It 'Normalize-DeployToRepo GitGpgProgram はベア名へ戻す' {
        $content = "`tprogram = C:\\x\\op-ssh-sign.exe`n"
        (Normalize-DeployToRepo 'GitGpgProgram' $content) | Should -Match "`tprogram = op-ssh-sign\.exe"
    }
    It 'Expand-RepoToDeploy GitGpgProgram はこの PC の絶対パスへ展開する' {
        Mock Get-OpSshSignPath { 'C:\Users\me\op-ssh-sign.exe' }
        $content = "`tprogram = op-ssh-sign.exe`n"
        (Expand-RepoToDeploy 'GitGpgProgram' $content) | Should -Match 'program = C:\\\\Users\\\\me\\\\op-ssh-sign\.exe'
    }
    It '未知の Transform は内容を変えない' {
        (Expand-RepoToDeploy 'Nope' 'abc')   | Should -Be 'abc'
        (Normalize-DeployToRepo 'Nope' 'abc') | Should -Be 'abc'
    }
}

Describe 'Invoke-BoochWinSync' {
    BeforeEach {
        $script:Dot = Join-Path $TestDrive ('d_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dot -Force | Out-Null
        # 表示は抑止、エンジンはモックして呼び出しだけ観測する。
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Warn {}; Mock Write-Fail {}; Mock Write-Info {}
        Mock Deploy-Pair {}
        Mock Import-Pair {}
    }

    It 'repo ファイルが無ければ Fail を出し deploy しない' {
        $pair = New-Pair -Dot $script:Dot -Repo 'x/none.txt' -Dest (Join-Path $TestDrive 'dst1.txt') -NoRepoFile
        Invoke-BoochWinSync -Pairs @($pair) -DotfilesDir $script:Dot
        Should -Invoke Write-Fail -Times 1
        Should -Invoke Deploy-Pair -Times 0
    }

    It 'dest が無ければ新規 deploy する' {
        $pair = New-Pair -Dot $script:Dot -Repo 'a.txt' -Dest (Join-Path $TestDrive ('new_' + [guid]::NewGuid().ToString('N') + '.txt'))
        Invoke-BoochWinSync -Pairs @($pair) -DotfilesDir $script:Dot
        Should -Invoke Deploy-Pair -Times 1
    }

    It '一致していれば何もしない' {
        $dest = Join-Path $TestDrive ('eq_' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $dest -Value 'same' -Encoding UTF8
        $pair = New-Pair -Dot $script:Dot -Repo 'b.txt' -Dest $dest
        Mock Test-PairInSync { $true }
        Invoke-BoochWinSync -Pairs @($pair) -DotfilesDir $script:Dot
        Should -Invoke Deploy-Pair -Times 0
        Should -Invoke Import-Pair -Times 0
    }

    It '差分 + [r] で repo → 環境 deploy する' {
        $dest = Join-Path $TestDrive ('r_' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $dest -Value 'env' -Encoding UTF8
        $pair = New-Pair -Dot $script:Dot -Repo 'c.txt' -Dest $dest -RepoContent 'repo'
        Mock Test-PairInSync { $false }
        Mock Read-Host { 'r' }
        Invoke-BoochWinSync -Pairs @($pair) -DotfilesDir $script:Dot
        Should -Invoke Deploy-Pair -Times 1
        Should -Invoke Import-Pair -Times 0
    }

    It '差分 + [e] で 環境 → repo import する' {
        $dest = Join-Path $TestDrive ('e_' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $dest -Value 'env' -Encoding UTF8
        $pair = New-Pair -Dot $script:Dot -Repo 'd.txt' -Dest $dest -RepoContent 'repo'
        Mock Test-PairInSync { $false }
        Mock Read-Host { 'e' }
        Invoke-BoochWinSync -Pairs @($pair) -DotfilesDir $script:Dot
        Should -Invoke Import-Pair -Times 1
        Should -Invoke Deploy-Pair -Times 0
    }

    It '差分 + [s] で何もしない' {
        $dest = Join-Path $TestDrive ('s_' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $dest -Value 'env' -Encoding UTF8
        $pair = New-Pair -Dot $script:Dot -Repo 'e.txt' -Dest $dest -RepoContent 'repo'
        Mock Test-PairInSync { $false }
        Mock Read-Host { 's' }
        Invoke-BoochWinSync -Pairs @($pair) -DotfilesDir $script:Dot
        Should -Invoke Deploy-Pair -Times 0
        Should -Invoke Import-Pair -Times 0
    }
}

Describe 'Copy-FilesIfChanged (一方向配置)' {
    BeforeEach {
        $script:Src = Join-Path $TestDrive ('src_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:Dst = Join-Path $TestDrive ('dst_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force $script:Src | Out-Null
    }

    It '配置先が無ければ作って全部コピーする' {
        Set-Content (Join-Path $script:Src 'a.pub') 'A' -NoNewline
        Set-Content (Join-Path $script:Src 'b.pub') 'B' -NoNewline
        $copied = Copy-FilesIfChanged $script:Src $script:Dst
        @($copied).Count | Should -Be 2
        (Get-Content (Join-Path $script:Dst 'b.pub') -Raw) | Should -Be 'B'
    }

    It '内容が同じなら再コピーしない (冪等)' {
        Set-Content (Join-Path $script:Src 'a.pub') 'A' -NoNewline
        [void](Copy-FilesIfChanged $script:Src $script:Dst)
        $copied = Copy-FilesIfChanged $script:Src $script:Dst
        @($copied).Count | Should -Be 0
    }

    It '内容が違うものだけ上書きする' {
        Set-Content (Join-Path $script:Src 'a.pub') 'A' -NoNewline
        Set-Content (Join-Path $script:Src 'b.pub') 'B' -NoNewline
        [void](Copy-FilesIfChanged $script:Src $script:Dst)
        Set-Content (Join-Path $script:Src 'b.pub') 'B2' -NoNewline
        $copied = Copy-FilesIfChanged $script:Src $script:Dst
        @($copied) | Should -Be @('b.pub')
        (Get-Content (Join-Path $script:Dst 'b.pub') -Raw) | Should -Be 'B2'
    }

    It 'Filter で対象を絞れる' {
        Set-Content (Join-Path $script:Src 'a.pub') 'A' -NoNewline
        Set-Content (Join-Path $script:Src 'note.txt') 'N' -NoNewline
        $copied = Copy-FilesIfChanged $script:Src $script:Dst -Filter '*.pub'
        @($copied) | Should -Be @('a.pub')
    }

    It '元ディレクトリが無ければ空配列' {
        (Copy-FilesIfChanged (Join-Path $TestDrive 'nope') $script:Dst).Count | Should -Be 0
    }
}

Describe 'Test-DirectoryInSync (実体コピーの鮮度判定)' {
    BeforeEach {
        $script:Src = Join-Path $TestDrive ('dsrc_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:Dst = Join-Path $TestDrive ('ddst_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force (Join-Path $script:Src 'sub') | Out-Null
        Set-Content (Join-Path $script:Src 'SKILL.md') 'body' -NoNewline
        Set-Content (Join-Path $script:Src 'sub\extra.md') 'x' -NoNewline
        Copy-Item -LiteralPath $script:Src -Destination $script:Dst -Recurse
    }

    It '再帰的に内容が一致していれば true' {
        Test-DirectoryInSync -SrcDir $script:Src -DstDir $script:Dst | Should -BeTrue
    }

    It '配布元だけ更新されていれば false (コピー方式が黙って古びるのを検出する)' {
        Set-Content (Join-Path $script:Src 'SKILL.md') 'body2' -NoNewline
        Test-DirectoryInSync -SrcDir $script:Src -DstDir $script:Dst | Should -BeFalse
    }

    It '配布元にファイルが増えていれば false' {
        Set-Content (Join-Path $script:Src 'NEW.md') 'n' -NoNewline
        Test-DirectoryInSync -SrcDir $script:Src -DstDir $script:Dst | Should -BeFalse
    }

    It '配備先に余計なファイルが残っていれば false' {
        Set-Content (Join-Path $script:Dst 'stale.md') 's' -NoNewline
        Test-DirectoryInSync -SrcDir $script:Src -DstDir $script:Dst | Should -BeFalse
    }

    It '入れ子のファイルの差分も見る' {
        Set-Content (Join-Path $script:Dst 'sub\extra.md') 'y' -NoNewline
        Test-DirectoryInSync -SrcDir $script:Src -DstDir $script:Dst | Should -BeFalse
    }

    It 'どちらかが存在しなければ false' {
        Test-DirectoryInSync -SrcDir $script:Src -DstDir (Join-Path $TestDrive 'nope') | Should -BeFalse
        Test-DirectoryInSync -SrcDir (Join-Path $TestDrive 'nope') -DstDir $script:Dst | Should -BeFalse
    }
}
