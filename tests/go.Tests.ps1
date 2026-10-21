#requires -Version 5.1
# lib/go.ps1 の Go 本体の導入を検証する (Pester 5)。配布一覧の取得、zip の取得、msiexec の
# 実行は seam をモックし、実際のネットワークとインストーラーは使わない。展開先の差し替えは
# TestDrive の実ファイルで確かめる。
#
# 見たいのは次の 4 点。
# - 導入する条件 (未導入 / 古い) と、しない条件 (最新 / 導入済みが新しい / 比較できない / 一覧を引けない)
# - 展開する前の検査 (アーキに合う zip の有無、ファイル名の形、SHA256 の照合)
# - 差し替えに失敗しても既存の展開先を壊さず、一時フォルダを残さないこと
# - MSI 版の削除は管理者権限があるときだけ行い、zip の導入より後に回すこと

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')
    . (Join-Path $lib 'download.ps1')
    . (Join-Path $lib 'winget.ps1')
    . (Join-Path $lib 'go.ps1')

    # モックの Save-GoArchive が書く中身と、その SHA256。
    $script:ZipBody = 'fake zip body'
    $probe = Join-Path $TestDrive 'probe.zip'
    Set-Content -LiteralPath $probe -Value $script:ZipBody -NoNewline
    $script:ZipSha = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash.ToLowerInvariant()

    function New-TestGoRelease {
        param([string]$Version = 'go1.27.2', [string]$Sha = $script:ZipSha)
        [pscustomobject]@{
            version = $Version
            stable  = $true
            files   = @(
                [pscustomobject]@{ filename = "$Version.windows-amd64.msi"; os = 'windows'; arch = 'amd64'; kind = 'installer'; sha256 = 'msi' }
                [pscustomobject]@{ filename = "$Version.windows-arm64.zip"; os = 'windows'; arch = 'arm64'; kind = 'archive';   sha256 = $Sha }
                [pscustomobject]@{ filename = "$Version.windows-amd64.zip"; os = 'windows'; arch = 'amd64'; kind = 'archive';   sha256 = $Sha }
                [pscustomobject]@{ filename = "$Version.linux-amd64.tar.gz"; os = 'linux';  arch = 'amd64'; kind = 'archive';   sha256 = 'tgz' }
            )
        }
    }

    # 配布物と同じ形 (go\VERSION と go\bin\go.exe) の展開結果を $Destination に作る。
    function New-TestGoTree {
        param([string]$Destination, [string]$Version = 'go1.27.2')
        $bin = Join-Path $Destination 'go\bin'
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        Set-Content -LiteralPath (Join-Path $Destination 'go\VERSION') -Value "$Version`ntime 2026-10-01T00:00:00Z"
        Set-Content -LiteralPath (Join-Path $bin 'go.exe') -Value 'fake'
    }
}

Describe 'ConvertTo-GoVersion' {
    It 'go1.X.Y と go1.X を [version] にする' {
        ConvertTo-GoVersion 'go1.27.2' | Should -Be ([version]'1.27.2')
        ConvertTo-GoVersion 'go1.20'   | Should -Be ([version]'1.20')
    }

    It 'rc / beta / 空は $null にする' {
        ConvertTo-GoVersion 'go1.28rc1'   | Should -BeNullOrEmpty
        ConvertTo-GoVersion 'go1.28beta1' | Should -BeNullOrEmpty
        ConvertTo-GoVersion ''            | Should -BeNullOrEmpty
    }

    It 'パッチ版の桁を数値として比べる (1.27.10 は 1.27.9 より新しい)' {
        (ConvertTo-GoVersion 'go1.27.10') -gt (ConvertTo-GoVersion 'go1.27.9') | Should -BeTrue
    }
}

Describe 'Get-GoRelease' {
    It '並び順に頼らず、安定版のうち版が最大のものを返す' {
        Mock Invoke-RestMethod {
            @(
                [pscustomobject]@{ version = 'go1.26.9';  stable = $true }
                [pscustomobject]@{ version = 'go1.27.10'; stable = $true }
                [pscustomobject]@{ version = 'go1.27.9';  stable = $true }
            )
        }
        (Get-GoRelease).version | Should -Be 'go1.27.10'
    }

    It '安定版でないものと、版を比較できないものは選ばない' {
        Mock Invoke-RestMethod {
            @(
                [pscustomobject]@{ version = 'go1.28rc1'; stable = $false }
                [pscustomobject]@{ version = 'go1.28.0';  stable = $false }
                [pscustomobject]@{ version = 'devel';     stable = $true }
                [pscustomobject]@{ version = 'go1.27.2';  stable = $true }
            )
        }
        (Get-GoRelease).version | Should -Be 'go1.27.2'
    }

    It '取得に失敗したとき、安定版が無いときは $null を返す' {
        Mock Invoke-RestMethod { throw 'offline' }
        Get-GoRelease | Should -BeNullOrEmpty
        Mock Invoke-RestMethod { @() }
        Get-GoRelease | Should -BeNullOrEmpty
    }
}

Describe 'Get-GoInstalledVersion' {
    BeforeAll {
        # 実物の go の代わり。関数は実行ファイルより先に解決される。
        function go {
            $script:SeenToolchain = $env:GOTOOLCHAIN
            $script:GoOutput
        }
    }
    BeforeEach {
        $script:PrevToolchain = $env:GOTOOLCHAIN
        $script:SeenToolchain = $null
        $script:GoOutput = 'go version go1.27.2 windows/amd64'
        Mock Test-Cmd { $true }
    }
    AfterEach { $env:GOTOOLCHAIN = $script:PrevToolchain }

    It 'go version の 3 語目を返す' {
        Get-GoInstalledVersion | Should -Be 'go1.27.2'
    }

    It 'GOTOOLCHAIN=local で呼び、呼んだ後は元の値へ戻す' {
        $env:GOTOOLCHAIN = 'go1.26.0'
        Get-GoInstalledVersion | Should -Be 'go1.27.2'
        $script:SeenToolchain | Should -Be 'local'
        $env:GOTOOLCHAIN | Should -Be 'go1.26.0'

        $env:GOTOOLCHAIN = $null
        Get-GoInstalledVersion | Out-Null
        $env:GOTOOLCHAIN | Should -BeNullOrEmpty
    }

    It 'go が無いとき、出力が版の形でないときは空を返す' {
        $script:GoOutput = ''
        Get-GoInstalledVersion | Should -Be ''
        Mock Test-Cmd { $false }
        $script:GoOutput = 'go version go1.27.2 windows/amd64'
        Get-GoInstalledVersion | Should -Be ''
    }
}

Describe 'Get-GoArch' {
    BeforeEach {
        $script:PrevArch  = $env:PROCESSOR_ARCHITECTURE
        $script:PrevW6432 = $env:PROCESSOR_ARCHITEW6432
        $env:PROCESSOR_ARCHITEW6432 = $null
    }
    AfterEach {
        $env:PROCESSOR_ARCHITECTURE = $script:PrevArch
        $env:PROCESSOR_ARCHITEW6432 = $script:PrevW6432
    }

    It 'プロセッサのアーキを go.dev の名前にする' {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'; Get-GoArch | Should -Be 'amd64'
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'; Get-GoArch | Should -Be 'arm64'
        $env:PROCESSOR_ARCHITECTURE = 'x86';   Get-GoArch | Should -Be '386'
    }

    It '32bit プロセスでは OS 側のアーキを使う' {
        $env:PROCESSOR_ARCHITECTURE = 'x86'
        $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
        Get-GoArch | Should -Be 'amd64'
    }

    It '対応しないアーキは空を返す' {
        $env:PROCESSOR_ARCHITECTURE = 'IA64'
        Get-GoArch | Should -Be ''
    }
}

Describe 'Get-GoLatestVersion' {
    It '配布一覧の版を返し、引けなければ空を返す' {
        Mock Get-GoRelease { New-TestGoRelease }
        Get-GoLatestVersion | Should -Be 'go1.27.2'
        Mock Get-GoRelease { $null }
        Get-GoLatestVersion | Should -Be ''
    }
}

Describe 'Get-GoDirVersion' {
    It 'VERSION の 1 行目を返す' {
        $dir = Join-Path $TestDrive 'ver-ok'
        New-TestGoTree -Destination $dir -Version 'go1.27.3'
        Get-GoDirVersion -Dir (Join-Path $dir 'go') | Should -Be 'go1.27.3'
    }

    It 'フォルダや VERSION が無いとき、中身が版の形でないときは空を返す' {
        Get-GoDirVersion -Dir (Join-Path $TestDrive 'nothing') | Should -Be ''
        $dir = Join-Path $TestDrive 'ver-bad'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'VERSION') -Value 'devel +abc'
        Get-GoDirVersion -Dir $dir | Should -Be ''
    }
}

Describe 'Update-GoDir' {
    BeforeEach {
        $script:Parent  = Join-Path $TestDrive ('swap-' + [guid]::NewGuid().ToString('N'))
        $script:Target  = Join-Path $script:Parent 'Go'
        $script:ZipPath = Join-Path $TestDrive 'any.zip'
        Mock Expand-GoArchive { New-TestGoTree -Destination $Destination -Version 'go1.27.2' }
        # 既存の展開先 (go1.27.0) を $script:Target に作る。
        function New-TestOldGo {
            $seed = Join-Path $TestDrive ('seed-' + [guid]::NewGuid().ToString('N'))
            New-TestGoTree -Destination $seed -Version 'go1.27.0'
            New-Item -ItemType Directory -Force -Path $script:Parent | Out-Null
            Move-Item (Join-Path $seed 'go') $script:Target
        }
    }

    It '未導入なら展開先を作る' {
        Update-GoDir -ZipPath $script:ZipPath -InstallDir $script:Target
        Get-GoDirVersion -Dir $script:Target | Should -Be 'go1.27.2'
    }

    It '既存の展開先を差し替え、一時フォルダを残さない' {
        New-TestOldGo
        Set-Content -LiteralPath (Join-Path $script:Target 'stale.txt') -Value 'old'
        Update-GoDir -ZipPath $script:ZipPath -InstallDir $script:Target
        Get-GoDirVersion -Dir $script:Target | Should -Be 'go1.27.2'
        Test-Path -LiteralPath (Join-Path $script:Target 'stale.txt') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Parent -Force).Name | Should -Be @('Go')
    }

    It '前回の実行が残した一時フォルダを片付ける' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Parent '.Go-old-leftover') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Parent '.Go-new-leftover') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Parent 'OtherApp') | Out-Null
        Update-GoDir -ZipPath $script:ZipPath -InstallDir $script:Target
        @(Get-ChildItem -LiteralPath $script:Parent -Force).Name | Sort-Object | Should -Be @('Go', 'OtherApp')
    }

    It '展開結果に go.exe が無ければ差し替えず、既存の展開先を残す' {
        New-TestOldGo
        Mock Expand-GoArchive { New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'go') | Out-Null }
        { Update-GoDir -ZipPath $script:ZipPath -InstallDir $script:Target } | Should -Throw '*go.exe*'
        Get-GoDirVersion -Dir $script:Target | Should -Be 'go1.27.0'
        @(Get-ChildItem -LiteralPath $script:Parent -Force).Name | Should -Be @('Go')
    }

    It '前回の実行が退避と差し替えの間で止まっていたら、退避先から旧版を戻す' {
        New-TestOldGo
        Move-Item $script:Target (Join-Path $script:Parent '.Go-old-crashed')
        Mock Expand-GoArchive { throw 'tar.exe failed (exit 1)' }
        { Update-GoDir -ZipPath $script:ZipPath -InstallDir $script:Target } | Should -Throw
        Get-GoDirVersion -Dir $script:Target | Should -Be 'go1.27.0'
        @(Get-ChildItem -LiteralPath $script:Parent -Force).Name | Should -Be @('Go')
    }

    It '新しい版を置けず旧版も戻せなければ、退避先を消さずに残す' {
        New-TestOldGo
        # 退避 (Go → .Go-old-*) は通し、展開先へ置く移動 (新しい版と旧版の戻し) だけを失敗させる
        Mock Move-Item { throw 'locked' } -ParameterFilter { $Destination -eq $script:Target }
        { Update-GoDir -ZipPath $script:ZipPath -InstallDir $script:Target } | Should -Throw '*旧版*'
        $kept = @(Get-ChildItem -LiteralPath $script:Parent -Force -Filter '.Go-old-*')
        $kept.Count | Should -Be 1
        Get-GoDirVersion -Dir $kept[0].FullName | Should -Be 'go1.27.0'
    }

    It '展開に失敗したら既存の展開先を残す' {
        New-TestOldGo
        Mock Expand-GoArchive { throw 'tar.exe failed (exit 1)' }
        { Update-GoDir -ZipPath $script:ZipPath -InstallDir $script:Target } | Should -Throw '*tar.exe*'
        Get-GoDirVersion -Dir $script:Target | Should -Be 'go1.27.0'
        @(Get-ChildItem -LiteralPath $script:Parent -Force).Name | Should -Be @('Go')
    }
}

Describe 'Remove-GoMsiProduct' {
    BeforeEach {
        $script:Products = @([pscustomobject]@{ ProductCode = '{AAAA-BBBB}'; Version = '1.27.3' })
        Mock Test-IsElevated { $true }
        Mock Invoke-GoMsiUninstall { 0 }
        Mock Write-Info {}
        Mock Write-Ok {}
        Mock Write-Warn {}
        Mock Write-Fail {}
    }

    It '管理者権限があれば msiexec /x で削除して $true を返す' {
        Remove-GoMsiProduct -Products $script:Products | Should -BeTrue
        Should -Invoke Invoke-GoMsiUninstall -Times 1 -Exactly -ParameterFilter { $ProductCode -eq '{AAAA-BBBB}' }
    }

    It '3010 も成功として扱う' {
        Mock Invoke-GoMsiUninstall { 3010 }
        Remove-GoMsiProduct -Products $script:Products | Should -BeTrue
        Should -Invoke Write-Fail -Times 0 -Exactly
    }

    It '管理者権限が無ければ削除せず、警告して $false を返す' {
        Mock Test-IsElevated { $false }
        Remove-GoMsiProduct -Products $script:Products | Should -BeFalse
        Should -Invoke Invoke-GoMsiUninstall -Times 0 -Exactly
        Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Msg -like '*1.27.3*管理者*' }
    }

    It 'msiexec が失敗したら失敗を表示して $false を返す' {
        Mock Invoke-GoMsiUninstall { 1603 }
        Remove-GoMsiProduct -Products $script:Products | Should -BeFalse
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*exit 1603*' }
    }
}

Describe 'Install-Go' {
    BeforeEach {
        # $script:DirVer は展開先の版、$script:PathVer は PATH で見つかる go の版。
        # Update-GoDir のモックが成功すると、どちらも最新へ進める。
        $script:InstallDir = Join-Path $TestDrive 'Programs\Go'
        $script:DirVer   = 'go1.27.0'
        $script:PathVer  = 'go1.27.0'
        $script:SavedTo  = $null
        $script:Calls    = [System.Collections.Generic.List[string]]::new()
        Mock Get-GoRelease { New-TestGoRelease }
        Mock Get-GoDirVersion { $script:DirVer }
        Mock Get-GoInstalledVersion { $script:PathVer }
        Mock Get-GoArch { 'amd64' }
        Mock Get-GoMsiProduct { @() }
        Mock Save-GoArchive {
            $script:SavedTo = $OutFile
            Set-Content -LiteralPath $OutFile -Value $script:ZipBody -NoNewline
        }
        Mock Update-GoDir { $script:Calls.Add('update'); $script:DirVer = 'go1.27.2'; $script:PathVer = 'go1.27.2' }
        Mock Remove-GoMsiProduct { $script:Calls.Add('msi'); $true }
        Mock Get-GoPathBin { 'C:\Users\me\go\bin' }
        Mock Add-UserPathEntry { $false }
        Mock Update-SessionPath {}
        Mock Write-Info {}
        Mock Write-Ok {}
        Mock Write-Warn {}
        Mock Write-Fail {}
    }

    It '古ければアーキに合う zip を取得して差し替え、PATH を整えて一時ファイルを残さない' {
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Save-GoArchive -Times 1 -Exactly -ParameterFilter { $FileName -eq 'go1.27.2.windows-amd64.zip' }
        Should -Invoke Update-GoDir -Times 1 -Exactly -ParameterFilter { $ZipPath -eq $script:SavedTo -and $InstallDir -eq $script:InstallDir }
        Should -Invoke Add-UserPathEntry -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $script:InstallDir 'bin') }
        Should -Invoke Update-SessionPath -Times 1 -Exactly
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -like '*go1.27.0*go1.27.2*' }
        Test-Path -LiteralPath (Split-Path $script:SavedTo -Parent) | Should -BeFalse
    }

    It '管理者権限を求めない (展開先はユーザー領域)' {
        Mock Test-IsElevated { $false }
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Update-GoDir -Times 1 -Exactly
        Should -Invoke Write-Warn -Times 0 -Exactly
    }

    It '未導入なら最新を入れる' {
        $script:DirVer = ''; $script:PathVer = ''
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Update-GoDir -Times 1 -Exactly
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -eq 'Go: go1.27.2' }
    }

    It 'arm64 では arm64 の zip を選ぶ' {
        Mock Get-GoArch { 'arm64' }
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Save-GoArchive -Times 1 -Exactly -ParameterFilter { $FileName -eq 'go1.27.2.windows-arm64.zip' }
    }

    It '最新なら何も取得しない' {
        $script:DirVer = 'go1.27.2'; $script:PathVer = 'go1.27.2'
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Save-GoArchive -Times 0 -Exactly
        Should -Invoke Update-GoDir -Times 0 -Exactly
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -like '*up to date*' }
    }

    It '展開先が新しいとき、または rc で比較できないときは触らない' {
        $script:DirVer = 'go1.28.0'
        Install-Go -InstallDir $script:InstallDir
        $script:DirVer = 'go1.28rc1'
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Save-GoArchive -Times 0 -Exactly
        Should -Invoke Update-GoDir -Times 0 -Exactly
    }

    It '展開先が空で MSI 版の go が新しければ触らない' {
        $script:DirVer = ''; $script:PathVer = 'go1.28.0'
        Mock Get-GoMsiProduct { @([pscustomobject]@{ ProductCode = '{AAAA}'; Version = '1.28.0' }) }
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Update-GoDir -Times 0 -Exactly
        Should -Invoke Remove-GoMsiProduct -Times 0 -Exactly
    }

    It 'MSI 以外の経路で入った go が PATH にあれば、古くても二重に入れない' {
        $script:DirVer = ''; $script:PathVer = 'go1.27.0'
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Save-GoArchive -Times 0 -Exactly
        Should -Invoke Add-UserPathEntry -Times 0 -Exactly
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -like '*別の経路*' }
    }

    It 'go install の出力先もユーザーの PATH へ足す (MSI の削除で消えるため)' {
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Add-UserPathEntry -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Users\me\go\bin' }
    }

    It 'MSI 版からの移行: 展開先へ入れてから MSI 版を削除する' {
        $script:DirVer = ''; $script:PathVer = 'go1.27.0'
        Mock Get-GoMsiProduct { @([pscustomobject]@{ ProductCode = '{AAAA}'; Version = '1.27.0' }) }
        Install-Go -InstallDir $script:InstallDir
        $script:Calls | Should -Be @('update', 'msi')
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -like '*go1.27.0*go1.27.2*' }
    }

    It '展開先が最新でも、MSI 版が残っていれば削除する' {
        $script:DirVer = 'go1.27.2'; $script:PathVer = 'go1.27.2'
        Mock Get-GoMsiProduct { @([pscustomobject]@{ ProductCode = '{AAAA}'; Version = '1.27.2' }) }
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Update-GoDir -Times 0 -Exactly
        Should -Invoke Remove-GoMsiProduct -Times 1 -Exactly
    }

    It 'MSI 版を削除できず PATH で古い go が先に見つかるときは、二重に警告しない' {
        Mock Get-GoMsiProduct { @([pscustomobject]@{ ProductCode = '{AAAA}'; Version = '1.27.0' }) }
        Mock Remove-GoMsiProduct { $false }
        Mock Update-GoDir { $script:DirVer = 'go1.27.2' }   # PATH の go は 1.27.0 のまま
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Write-Warn -Times 0 -Exactly
        Should -Invoke Write-Ok -Times 0 -Exactly
    }

    It '配布一覧を引けなければ警告だけ出し、最新とは表示しない' {
        Mock Get-GoRelease { $null }
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Write-Warn -Times 1 -Exactly
        Should -Invoke Write-Ok -Times 0 -Exactly
        Should -Invoke Update-GoDir -Times 0 -Exactly
    }

    It 'アーキに合う zip が無ければ失敗を表示して取得しない' {
        Mock Get-GoArch { '' }
        Install-Go -InstallDir $script:InstallDir
        Mock Get-GoArch { 'riscv64' }
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Write-Fail -Times 2 -Exactly
        Should -Invoke Save-GoArchive -Times 0 -Exactly
    }

    It '配布一覧のファイル名が zip の形でなければ取得しない' {
        Mock Get-GoRelease {
            $r = New-TestGoRelease
            ($r.files | Where-Object { $_.arch -eq 'amd64' -and $_.kind -eq 'archive' -and $_.os -eq 'windows' }).filename = '../evil.zip'
            $r
        }
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Write-Fail -Times 1 -Exactly
        Should -Invoke Save-GoArchive -Times 0 -Exactly
    }

    It 'SHA256 が一致しなければ展開せず、PATH にも MSI 版にも触れず、一時ファイルを残さない' {
        Mock Get-GoRelease { New-TestGoRelease -Sha ('0' * 64) }
        Mock Get-GoMsiProduct { @([pscustomobject]@{ ProductCode = '{AAAA}'; Version = '1.27.0' }) }
        { Install-Go -InstallDir $script:InstallDir } | Should -Not -Throw
        Should -Invoke Update-GoDir -Times 0 -Exactly
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*SHA256*' }
        Should -Invoke Add-UserPathEntry -Times 0 -Exactly
        Should -Invoke Remove-GoMsiProduct -Times 0 -Exactly
        Test-Path -LiteralPath (Split-Path $script:SavedTo -Parent) | Should -BeFalse
    }

    It 'SHA256 は大文字と小文字を区別せずに照合する' {
        Mock Get-GoRelease { New-TestGoRelease -Sha $script:ZipSha.ToUpperInvariant() }
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Update-GoDir -Times 1 -Exactly
    }

    It '取得や差し替えに失敗したら例外を外へ出さず、MSI 版を残す' {
        Mock Get-GoMsiProduct { @([pscustomobject]@{ ProductCode = '{AAAA}'; Version = '1.27.0' }) }
        Mock Save-GoArchive { throw 'download failed' }
        { Install-Go -InstallDir $script:InstallDir } | Should -Not -Throw
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*download failed*' }
        Mock Save-GoArchive { Set-Content -LiteralPath $OutFile -Value $script:ZipBody -NoNewline }
        Mock Update-GoDir { throw 'in use' }
        { Install-Go -InstallDir $script:InstallDir } | Should -Not -Throw
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*in use*' }
        Should -Invoke Remove-GoMsiProduct -Times 0 -Exactly
        Should -Invoke Update-SessionPath -Times 0 -Exactly
    }

    It '導入後も go version が最新を返さなければ警告する' {
        Mock Update-GoDir { $script:DirVer = 'go1.27.2' }
        Install-Go -InstallDir $script:InstallDir
        Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Msg -like '*go1.27.2*' }
        Should -Invoke Write-Ok -Times 0 -Exactly
    }
}
