#requires -Version 5.1
# lib/go.ps1 の Go 本体の導入を検証する (Pester 5)。配布一覧の取得、MSI の取得、msiexec の
# 実行は seam をモックし、実際のネットワークとインストーラーは使わない。
#
# 見たいのは次の 3 点。
# - 導入する条件 (未導入 / 古い) と、しない条件 (最新 / 導入済みが新しい / 比較できない / 一覧を引けない)
# - MSI を実行する前の検査 (管理者権限、アーキに合う MSI の有無、SHA256 の照合)
# - 失敗しても例外を外へ出さず、一時ファイルを残さないこと

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')
    . (Join-Path $lib 'download.ps1')
    . (Join-Path $lib 'winget.ps1')
    . (Join-Path $lib 'go.ps1')

    # モックの Save-GoInstaller が書く中身と、その SHA256。
    $script:MsiBody = 'fake msi body'
    $probe = Join-Path $TestDrive 'probe.msi'
    Set-Content -LiteralPath $probe -Value $script:MsiBody -NoNewline
    $script:MsiSha = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash.ToLowerInvariant()

    function New-TestGoRelease {
        param([string]$Version = 'go1.27.2', [string]$Sha = $script:MsiSha)
        [pscustomobject]@{
            version = $Version
            stable  = $true
            files   = @(
                [pscustomobject]@{ filename = "$Version.windows-amd64.zip"; os = 'windows'; arch = 'amd64'; kind = 'archive';   sha256 = 'zip' }
                [pscustomobject]@{ filename = "$Version.windows-arm64.msi"; os = 'windows'; arch = 'arm64'; kind = 'installer'; sha256 = $Sha }
                [pscustomobject]@{ filename = "$Version.windows-amd64.msi"; os = 'windows'; arch = 'amd64'; kind = 'installer'; sha256 = $Sha }
                [pscustomobject]@{ filename = "$Version.linux-amd64.tar.gz"; os = 'linux';  arch = 'amd64'; kind = 'archive';   sha256 = 'tgz' }
            )
        }
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

Describe 'Install-Go' {
    BeforeEach {
        # 導入済みの版。Invoke-GoInstaller のモックが成功すると最新へ進める。
        $script:Installed = 'go1.27.0'
        $script:SavedTo   = $null
        Mock Get-GoRelease { New-TestGoRelease }
        Mock Get-GoInstalledVersion { $script:Installed }
        Mock Get-GoArch { 'amd64' }
        Mock Test-IsElevated { $true }
        Mock Save-GoInstaller {
            $script:SavedTo = $OutFile
            Set-Content -LiteralPath $OutFile -Value $script:MsiBody -NoNewline
        }
        Mock Invoke-GoInstaller { $script:Installed = 'go1.27.2'; 0 }
        Mock Update-SessionPath {}
        Mock Write-Info {}
        Mock Write-Ok {}
        Mock Write-Warn {}
        Mock Write-Fail {}
    }

    It '古ければアーキに合う MSI を取得して実行し、PATH を組み直して一時ファイルを残さない' {
        Install-Go
        Should -Invoke Save-GoInstaller -Times 1 -Exactly -ParameterFilter { $FileName -eq 'go1.27.2.windows-amd64.msi' }
        Should -Invoke Invoke-GoInstaller -Times 1 -Exactly -ParameterFilter { $MsiPath -eq $script:SavedTo }
        Should -Invoke Update-SessionPath -Times 1 -Exactly
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -like '*go1.27.0*go1.27.2*' }
        Test-Path -LiteralPath (Split-Path $script:SavedTo -Parent) | Should -BeFalse
    }

    It '未導入なら最新を入れる' {
        $script:Installed = ''
        Install-Go
        Should -Invoke Invoke-GoInstaller -Times 1 -Exactly
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -eq 'Go: go1.27.2' }
    }

    It 'arm64 では arm64 の MSI を選ぶ' {
        Mock Get-GoArch { 'arm64' }
        Install-Go
        Should -Invoke Save-GoInstaller -Times 1 -Exactly -ParameterFilter { $FileName -eq 'go1.27.2.windows-arm64.msi' }
        Should -Invoke Invoke-GoInstaller -Times 1 -Exactly
    }

    It '最新なら何も取得しない' {
        $script:Installed = 'go1.27.2'
        Install-Go
        Should -Invoke Save-GoInstaller -Times 0 -Exactly
        Should -Invoke Invoke-GoInstaller -Times 0 -Exactly
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -like '*up to date*' }
    }

    It '導入済みが安定版より新しいとき、または rc で比較できないときは触らない' {
        $script:Installed = 'go1.28.0'
        Install-Go
        $script:Installed = 'go1.28rc1'
        Install-Go
        Should -Invoke Save-GoInstaller -Times 0 -Exactly
        Should -Invoke Invoke-GoInstaller -Times 0 -Exactly
    }

    It '配布一覧を引けなければ警告だけ出し、最新とは表示しない' {
        Mock Get-GoRelease { $null }
        Install-Go
        Should -Invoke Write-Warn -Times 1 -Exactly
        Should -Invoke Write-Ok -Times 0 -Exactly
        Should -Invoke Invoke-GoInstaller -Times 0 -Exactly
    }

    It '管理者権限が無ければ取得も実行もしない' {
        Mock Test-IsElevated { $false }
        Install-Go
        Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Msg -like '*管理者*' }
        Should -Invoke Save-GoInstaller -Times 0 -Exactly
        Should -Invoke Invoke-GoInstaller -Times 0 -Exactly
    }

    It 'アーキに合う MSI が無ければ失敗を表示して実行しない' {
        Mock Get-GoArch { '' }
        Install-Go
        Mock Get-GoArch { 'riscv64' }
        Install-Go
        Should -Invoke Write-Fail -Times 2 -Exactly
        Should -Invoke Save-GoInstaller -Times 0 -Exactly
    }

    It '配布一覧のファイル名が MSI の形でなければ取得しない' {
        Mock Get-GoRelease {
            $r = New-TestGoRelease
            ($r.files | Where-Object { $_.arch -eq 'amd64' -and $_.kind -eq 'installer' }).filename = '../evil.msi'
            $r
        }
        Install-Go
        Should -Invoke Write-Fail -Times 1 -Exactly
        Should -Invoke Save-GoInstaller -Times 0 -Exactly
    }

    It 'SHA256 が一致しなければ MSI を実行せず、一時ファイルを残さない' {
        Mock Get-GoRelease { New-TestGoRelease -Sha ('0' * 64) }
        { Install-Go } | Should -Not -Throw
        Should -Invoke Invoke-GoInstaller -Times 0 -Exactly
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*SHA256*' }
        Should -Invoke Update-SessionPath -Times 0 -Exactly
        Test-Path -LiteralPath (Split-Path $script:SavedTo -Parent) | Should -BeFalse
    }

    It 'SHA256 は大文字と小文字を区別せずに照合する' {
        Mock Get-GoRelease { New-TestGoRelease -Sha $script:MsiSha.ToUpperInvariant() }
        Install-Go
        Should -Invoke Invoke-GoInstaller -Times 1 -Exactly
    }

    It '取得に失敗したら実行せず、例外を外へ出さない' {
        Mock Save-GoInstaller { throw 'download failed' }
        { Install-Go } | Should -Not -Throw
        Should -Invoke Invoke-GoInstaller -Times 0 -Exactly
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*download failed*' }
    }

    It 'msiexec が非 0 で終わったら失敗を表示し、PATH に触れない' {
        Mock Invoke-GoInstaller { 1603 }
        { Install-Go } | Should -Not -Throw
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*exit 1603*' }
        Should -Invoke Update-SessionPath -Times 0 -Exactly
        Should -Invoke Write-Ok -Times 0 -Exactly
    }

    It 'msiexec の 3010 は成功として扱い、再起動が要ると伝える' {
        Mock Invoke-GoInstaller { $script:Installed = 'go1.27.2'; 3010 }
        Install-Go
        Should -Invoke Write-Fail -Times 0 -Exactly
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -like '*再起動*' }
    }

    It '導入後も go version が最新を返さなければ警告する' {
        Mock Invoke-GoInstaller { 0 }
        Install-Go
        Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Msg -like '*go1.27.2*' }
        Should -Invoke Write-Ok -Times 0 -Exactly
    }
}
