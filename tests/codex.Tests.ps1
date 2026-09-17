#requires -Version 5.1
# lib/codex.ps1 の導入まわりを検証する (Pester 5)。install.ps1 の取得と実行は seam を
# モックし、実際のインストーラーは走らせない。
#
# 見たいのは次の 3 点。
# - インストーラーへ渡す版と、失敗の検出 (終了コード)
# - 導入後に現セッションの PATH を組み直すこと (子プロセスの PATH 変更は親に届かない)
# - 旧版と旧単一バイナリ (~\.local\bin\codex.exe) を消す条件。別物や使用中の版を巻き込まないこと

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'winget.ps1')
    . (Join-Path $lib 'doctor.ps1')
    . (Join-Path $lib 'codex.ps1')

    # 見える bin dir をテストごとの一時ディレクトリへ向ける (実環境の codex を見ない)。
    # Pester 5 はファイル直下の BeforeEach を受け付けないので、使う Describe から呼ぶ。
    function Enter-TestCodexBinDir {
        $script:PrevInstallDir = $env:CODEX_INSTALL_DIR
        $env:CODEX_INSTALL_DIR = Join-Path $TestDrive ('bin_' + [guid]::NewGuid().ToString('N'))
    }
    function Exit-TestCodexBinDir { $env:CODEX_INSTALL_DIR = $script:PrevInstallDir }
}

Describe 'Install-Codex' {
    BeforeEach {
        $script:SavedTo = $null
        Mock Save-CodexInstaller { $script:SavedTo = $OutFile; Set-Content -LiteralPath $OutFile -Value '' }
        Mock Invoke-CodexInstaller { 0 }
        Mock Update-SessionPath {}
        Mock Remove-LegacyCodexBinary { $false }
        Mock Get-CodexCurrentReleaseName { '0.153.0-x86_64-pc-windows-msvc' }
        Mock Remove-CodexOldRelease {}
        Mock Write-Info {}
    }

    It '版を省略すると latest を渡す' {
        Install-Codex
        Should -Invoke Invoke-CodexInstaller -Times 1 -Exactly -ParameterFilter { $Release -eq 'latest' }
    }

    It 'rust-v / v 接頭辞を外した版を渡し、取得した install.ps1 を実行する' {
        Install-Codex -Version 'rust-v0.154.0'
        Should -Invoke Invoke-CodexInstaller -Times 1 -Exactly -ParameterFilter {
            $Release -eq '0.154.0' -and $ScriptPath -eq $script:SavedTo
        }
        Install-Codex -Version 'v0.155.0'
        Should -Invoke Invoke-CodexInstaller -Times 1 -Exactly -ParameterFilter { $Release -eq '0.155.0' }
    }

    It '成功したら PATH を組み直し、旧版と旧バイナリの削除を試み、一時ファイルを残さない' {
        Install-Codex
        Should -Invoke Update-SessionPath -Times 1 -Exactly
        Should -Invoke Remove-CodexOldRelease -Times 1 -Exactly -ParameterFilter { $Keep -eq '0.153.0-x86_64-pc-windows-msvc' }
        Should -Invoke Remove-LegacyCodexBinary -Times 1 -Exactly
        Test-Path -LiteralPath (Split-Path $script:SavedTo -Parent) | Should -BeFalse
    }

    It 'インストーラーが非 0 で終わったら throw し、PATH と旧版と旧バイナリに触れない' {
        Mock Invoke-CodexInstaller { 1 }
        { Install-Codex } | Should -Throw '*exit 1*'
        Should -Invoke Update-SessionPath -Times 0 -Exactly
        Should -Invoke Remove-CodexOldRelease -Times 0 -Exactly
        Should -Invoke Remove-LegacyCodexBinary -Times 0 -Exactly
    }

    It 'install.ps1 を取得できなければ実行しない' {
        Mock Save-CodexInstaller { throw 'download failed' }
        { Install-Codex } | Should -Throw '*download failed*'
        Should -Invoke Invoke-CodexInstaller -Times 0 -Exactly
    }
}

Describe 'Invoke-CodexInstaller' {
    It '子プロセスへ -Release と CODEX_NON_INTERACTIVE=1 を渡し、終了コードだけを返す' {
        # 実際に子の PowerShell を起動する。子が出力しても戻り値に混ざらないことも見る。
        $script = Join-Path $TestDrive 'fake-install.ps1'
        Set-Content -LiteralPath $script -Value @'
param([string]$Release)
Write-Output 'noise on stdout'
Write-Host 'noise on host'
if ($env:CODEX_NON_INTERACTIVE -ne '1') { exit 3 }
if ($Release -ne '1.2.3') { exit 4 }
exit 7
'@
        $prev = $env:CODEX_NON_INTERACTIVE
        $env:CODEX_NON_INTERACTIVE = 'keep-me'
        try {
            $code = Invoke-CodexInstaller -ScriptPath $script -Release '1.2.3' 6>$null
            $code | Should -Be 7
            $env:CODEX_NON_INTERACTIVE | Should -Be 'keep-me'
        } finally {
            $env:CODEX_NON_INTERACTIVE = $prev
        }
    }
}

Describe 'ConvertTo-CodexVersion' {
    It 'rust-v / v 接頭辞を外す' {
        ConvertTo-CodexVersion 'rust-v0.154.0' | Should -Be '0.154.0'
        ConvertTo-CodexVersion 'v0.154.0' | Should -Be '0.154.0'
        ConvertTo-CodexVersion '0.154.0' | Should -Be '0.154.0'
    }
}

Describe 'Remove-LegacyCodexBinary' {
    BeforeEach {
        Enter-TestCodexBinDir
        $script:Legacy = Join-Path $TestDrive ('legacy_' + [guid]::NewGuid().ToString('N') + '.exe')
    }
    AfterEach { Exit-TestCodexBinDir }

    It 'codex-cli を名乗る通常ファイルは消す' {
        Set-Content -LiteralPath $script:Legacy -Value 'x'
        Mock Get-CodexVersionOutput { 'codex-cli 0.150.0' }
        Remove-LegacyCodexBinary -Path $script:Legacy | Should -BeTrue
        Test-Path -LiteralPath $script:Legacy | Should -BeFalse
    }

    It 'codex-cli を名乗らないものは消さない' {
        Set-Content -LiteralPath $script:Legacy -Value 'x'
        Mock Get-CodexVersionOutput { 'something 1.0.0' }
        Remove-LegacyCodexBinary -Path $script:Legacy | Should -BeFalse
        Test-Path -LiteralPath $script:Legacy | Should -BeTrue
    }

    It '無ければ何もしない' {
        Mock Get-CodexVersionOutput { 'codex-cli 0.150.0' }
        Remove-LegacyCodexBinary -Path $script:Legacy | Should -BeFalse
        Should -Invoke Get-CodexVersionOutput -Times 0 -Exactly
    }

    It 'インストーラーの bin dir の codex.exe そのものは消さない' {
        New-Item -ItemType Directory -Force -Path $env:CODEX_INSTALL_DIR | Out-Null
        $inBin = Join-Path $env:CODEX_INSTALL_DIR 'codex.exe'
        Set-Content -LiteralPath $inBin -Value 'x'
        Mock Get-CodexVersionOutput { 'codex-cli 0.154.0' }
        Remove-LegacyCodexBinary -Path $inBin | Should -BeFalse
        Test-Path -LiteralPath $inBin | Should -BeTrue
    }
}

Describe 'Remove-CodexOldRelease' {
    BeforeEach {
        $script:PrevCodexHome = $env:CODEX_HOME
        $script:Home_ = Join-Path $TestDrive ('codexhome_' + [guid]::NewGuid().ToString('N'))
        $env:CODEX_HOME = $script:Home_
        $script:Releases = Join-Path $script:Home_ 'packages\standalone\releases'
        foreach ($n in @('0.1.0-t', '0.2.0-t', '0.3.0-t', '.staging.x')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $script:Releases $n) | Out-Null
        }
        Mock Write-Warn {}
    }
    AfterEach { $env:CODEX_HOME = $script:PrevCodexHome }

    BeforeAll {
        # インストーラーは current を junction で張る。junction を作れない環境 (Linux の pwsh) では symlink で代用する。
        function New-TestCurrentLink {
            param([string]$Name)
            $linkType = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
            New-Item -ItemType $linkType -Path (Join-Path $script:Home_ 'packages\standalone\current') `
                -Target (Join-Path $script:Releases $Name) | Out-Null
        }
    }

    It 'current と直前の版を残し、それより古い版を消す。.staging.* には触れない' {
        New-TestCurrentLink '0.3.0-t'
        Remove-CodexOldRelease -Keep '0.2.0-t'
        (Get-ChildItem -LiteralPath $script:Releases -Directory -Force).Name | Sort-Object |
            Should -Be @('.staging.x', '0.2.0-t', '0.3.0-t')
    }

    It '直前の版が無ければ current だけを残す' {
        New-TestCurrentLink '0.3.0-t'
        Remove-CodexOldRelease
        (Get-ChildItem -LiteralPath $script:Releases -Directory -Force).Name | Sort-Object |
            Should -Be @('.staging.x', '0.3.0-t')
    }

    It '名前を変えられない (使用中の) 版は中身に触れず残す' {
        New-TestCurrentLink '0.3.0-t'
        $marker = Join-Path $script:Releases '0.1.0-t\bin.txt'
        Set-Content -LiteralPath $marker -Value 'x'
        Mock Rename-Item { throw 'in use' }
        Remove-CodexOldRelease
        Test-Path -LiteralPath $marker | Should -BeTrue
        Should -Invoke Write-Warn -Times 2 -Exactly
    }

    It '前回消しきれなかった改名済みの版を消し直す' {
        New-TestCurrentLink '0.3.0-t'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Releases '.booch-old.0.0.9-t') | Out-Null
        Remove-CodexOldRelease -Keep '0.2.0-t'
        (Get-ChildItem -LiteralPath $script:Releases -Directory -Force).Name | Sort-Object |
            Should -Be @('.staging.x', '0.2.0-t', '0.3.0-t')
    }

    It 'current が無ければ何も消さない' {
        Remove-CodexOldRelease
        (Get-ChildItem -LiteralPath $script:Releases -Directory -Force).Count | Should -Be 4
    }
}

Describe 'Clear-LegacyCodexBinary' {
    It '削除できなくても throw せず警告する' {
        Mock Remove-LegacyCodexBinary { throw 'file in use' }
        Mock Write-Warn {}
        { Clear-LegacyCodexBinary } | Should -Not -Throw
        Should -Invoke Write-Warn -Times 1 -Exactly
    }
}

Describe 'Get-CodexInstalledVersion' {
    BeforeEach { Enter-TestCodexBinDir }
    AfterEach { Exit-TestCodexBinDir }

    It 'bin dir に codex.exe が無ければ空 (PATH 上に旧バイナリがあっても未導入扱い)' {
        Mock Get-CodexVersionOutput { 'codex-cli 0.150.0' }
        Get-CodexInstalledVersion | Should -Be ''
        Should -Invoke Get-CodexVersionOutput -Times 0 -Exactly
    }

    It 'bin dir の codex.exe の版を返す' {
        New-Item -ItemType Directory -Force -Path $env:CODEX_INSTALL_DIR | Out-Null
        Set-Content -LiteralPath (Join-Path $env:CODEX_INSTALL_DIR 'codex.exe') -Value 'x'
        Mock Get-CodexVersionOutput { 'codex-cli 0.154.0 (abcdef)' }
        Get-CodexInstalledVersion | Should -Be '0.154.0'
    }
}
