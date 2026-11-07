#requires -Version 5.1
# lib/codex.ps1 の導入まわりを検証する (Pester 5)。install.ps1 の取得と実行は seam を
# モックし、実際のインストーラーは走らせない。
#
# 見たいのは次の 5 点。
# - インストーラーへ渡す版と、失敗の検出 (終了コード)
# - install.ps1 を入れる版のタグの資産から取り、digest で照合できなければ実行しないこと
# - 導入後に現セッションの PATH を組み直すこと (子プロセスの PATH 変更は親に届かない)
# - 旧版と旧単一バイナリ (~\.local\bin\codex.exe) を消す条件。別物や使用中の版を巻き込まないこと
# - 共有デーモンの版のずれの判定と、入れ替えの条件 (確認を省かない、昇格中は入れ替えない)

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'winget.ps1')
    . (Join-Path $lib 'doctor.ps1')
    . (Join-Path $lib 'system.ps1')
    . (Join-Path $lib 'download.ps1')
    . (Join-Path $lib 'github.ps1')
    . (Join-Path $lib 'codex.ps1')
    # エントリ側で定義される関数の代わり。
    function Get-EffectiveTimeout { param($Sec) $Sec }

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
        Mock Get-CodexLatestVersion { '0.160.0' }
        Mock Invoke-CodexInstaller { 0 }
        Mock Update-SessionPath {}
        Mock Remove-LegacyCodexBinary { $false }
        Mock Get-CodexCurrentReleaseName { '0.153.0-x86_64-pc-windows-msvc' }
        Mock Remove-CodexOldRelease {}
        Mock Write-Info {}
    }

    It '版を省略すると GitHub の最新タグの install.ps1 を取り、インストーラーには latest を渡す' {
        Install-Codex
        Should -Invoke Get-CodexLatestVersion -Times 1 -Exactly -ParameterFilter { $Repo -eq 'openai/codex' }
        Should -Invoke Save-CodexInstaller -Times 1 -Exactly -ParameterFilter { $Version -eq '0.160.0' }
        Should -Invoke Invoke-CodexInstaller -Times 1 -Exactly -ParameterFilter { $Release -eq 'latest' }
    }

    It '最新タグを取れなければ install.ps1 を取らない' {
        Mock Get-CodexLatestVersion { '' }
        { Install-Codex } | Should -Throw '*最新タグ*'
        Should -Invoke Save-CodexInstaller -Times 0 -Exactly
        Should -Invoke Invoke-CodexInstaller -Times 0 -Exactly
    }

    It 'rust-v / v 接頭辞を外した版で install.ps1 を取り、その版を渡して実行する' {
        Install-Codex -Version 'rust-v0.154.0'
        Should -Invoke Get-CodexLatestVersion -Times 0 -Exactly
        Should -Invoke Save-CodexInstaller -Times 1 -Exactly -ParameterFilter { $Version -eq '0.154.0' }
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

Describe 'Save-CodexInstaller' {
    BeforeEach {
        $script:Body = "Write-Output installer`n"
        $script:BodySha = [BitConverter]::ToString(
            [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($script:Body))
        ).Replace('-', '').ToLowerInvariant()
        $script:Out = Join-Path $TestDrive ('install_' + [guid]::NewGuid().ToString('N') + '.ps1')
        # 取得は固定の中身を書くだけにする (ネットワークに出ない)。
        Mock Invoke-Download { [IO.File]::WriteAllText($OutFile, $script:Body) }
    }

    It '入れる版のタグの install.ps1 の digest を引き、同じタグの資産を取って照合が通る' {
        Mock Get-GitHubReleaseAssetDigest { $script:BodySha }
        Save-CodexInstaller -OutFile $script:Out -Version '0.160.0'
        Should -Invoke Get-GitHubReleaseAssetDigest -Times 1 -Exactly -ParameterFilter {
            $Repo -eq 'openai/codex' -and $Tag -eq 'rust-v0.160.0' -and $Name -eq 'install.ps1'
        }
        Should -Invoke Invoke-Download -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/openai/codex/releases/download/rust-v0.160.0/install.ps1'
        }
        Test-Path -LiteralPath $script:Out | Should -BeTrue
    }

    It 'digest と一致しなければ throw し、取得したファイルを残さない' {
        Mock Get-GitHubReleaseAssetDigest { '0' * 64 }
        { Save-CodexInstaller -OutFile $script:Out -Version '0.160.0' } | Should -Throw '*一致しない*'
        Test-Path -LiteralPath $script:Out | Should -BeFalse
    }

    # 取得したスクリプトをそのまま実行するので、digest が無いときも通さない。
    It 'digest が無ければ取得せずに throw する' {
        Mock Get-GitHubReleaseAssetDigest { '' }
        { Save-CodexInstaller -OutFile $script:Out -Version '0.160.0' } | Should -Throw '*digest が無い*'
        Should -Invoke Invoke-Download -Times 0 -Exactly
    }

    It '取得に失敗したら途中まで書かれたファイルを残さない' {
        Mock Get-GitHubReleaseAssetDigest { $script:BodySha }
        Mock Invoke-Download { [IO.File]::WriteAllText($OutFile, 'partial'); throw 'curl.exe failed (exit 28)' }
        { Save-CodexInstaller -OutFile $script:Out -Version '0.160.0' } | Should -Throw '*exit 28*'
        Test-Path -LiteralPath $script:Out | Should -BeFalse
    }

    It '版の形が不正なら API も取得も呼ばない' {
        Mock Get-GitHubReleaseAssetDigest { $script:BodySha }
        foreach ($v in @('latest', '0.160.0 ', '0.160.0/../x', '')) {
            { Save-CodexInstaller -OutFile $script:Out -Version $v } | Should -Throw
        }
        Should -Invoke Get-GitHubReleaseAssetDigest -Times 0 -Exactly
        Should -Invoke Invoke-Download -Times 0 -Exactly
    }

    It 'プレリリースの版は通す' {
        Mock Get-GitHubReleaseAssetDigest { $script:BodySha }
        Save-CodexInstaller -OutFile $script:Out -Version '0.168.0-alpha.1'
        Should -Invoke Invoke-Download -Times 1 -Exactly -ParameterFilter { $Uri -like '*/rust-v0.168.0-alpha.1/install.ps1' }
    }

    It 'digest の取得に失敗したら取得せずに throw する' {
        Mock Get-GitHubReleaseAssetDigest { throw 'api down' }
        { Save-CodexInstaller -OutFile $script:Out -Version '0.160.0' } | Should -Throw '*digest を取得できない*'
        Should -Invoke Invoke-Download -Times 0 -Exactly
    }
}

Describe 'Get-GitHubReleaseAssetDigest' {
    It '名前の一致する資産の sha256 digest を小文字の 16 進で返す' {
        $hex = 'AB' * 32
        Mock Invoke-RestMethod {
            [pscustomobject]@{ assets = @(
                    [pscustomobject]@{ name = 'install.sh'; digest = "sha256:$('cd' * 32)" },
                    [pscustomobject]@{ name = 'install.ps1'; digest = "sha256:$hex" }
                ) }
        }
        Get-GitHubReleaseAssetDigest -Repo 'openai/codex' -Tag 'rust-v0.1.0' -Name 'install.ps1' |
            Should -Be $hex.ToLowerInvariant()
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/openai/codex/releases/tags/rust-v0.1.0'
        }
    }

    It '資産が無い、または digest が無いときは空' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'install.ps1'; digest = $null }) }
        }
        Get-GitHubReleaseAssetDigest -Repo 'o/r' -Tag 't' -Name 'install.ps1' | Should -Be ''
        Get-GitHubReleaseAssetDigest -Repo 'o/r' -Tag 't' -Name 'other' | Should -Be ''
    }

    It 'API の取得に失敗したら throw する (digest が無いときと区別する)' {
        Mock Invoke-RestMethod { throw 'not found' }
        { Get-GitHubReleaseAssetDigest -Repo 'o/r' -Tag 't' -Name 'install.ps1' } | Should -Throw
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

Describe 'Invoke-CodexDaemonCommand' {
    BeforeEach { Enter-TestCodexBinDir }
    AfterEach { Exit-TestCodexBinDir }

    It 'bin dir に codex.exe が無ければ $null' {
        Invoke-CodexDaemonCommand -Command 'version' | Should -BeNullOrEmpty
    }

    It '起動できない codex.exe なら throw せず $null' {
        New-Item -ItemType Directory -Force -Path $env:CODEX_INSTALL_DIR | Out-Null
        Set-Content -LiteralPath (Join-Path $env:CODEX_INSTALL_DIR 'codex.exe') -Value 'not an exe'
        Invoke-CodexDaemonCommand -Command 'version' | Should -BeNullOrEmpty
    }
}

Describe 'Get-CodexDaemonVersion' {
    It '版が同じなら Drift は偽' {
        Mock Invoke-CodexDaemonCommand { '{"cliVersion":"0.159.2","appServerVersion":"0.159.2"}' }
        $v = Get-CodexDaemonVersion
        $v.Cli | Should -Be '0.159.2'
        $v.App | Should -Be '0.159.2'
        $v.Drift | Should -BeFalse
        Should -Invoke Invoke-CodexDaemonCommand -Times 1 -Exactly -ParameterFilter { $Command -eq 'version' }
    }

    It '版が違えば Drift は真' {
        Mock Invoke-CodexDaemonCommand { '{"cliVersion":"0.159.2","appServerVersion":"0.158.0"}' }
        (Get-CodexDaemonVersion).Drift | Should -BeTrue
    }

    It 'どちらかの版が空なら Drift は偽' {
        Mock Invoke-CodexDaemonCommand { '{"cliVersion":"0.159.2","appServerVersion":null}' }
        $v = Get-CodexDaemonVersion
        $v.App | Should -Be ''
        $v.Drift | Should -BeFalse
        Mock Invoke-CodexDaemonCommand { '{"appServerVersion":"0.158.0"}' }
        (Get-CodexDaemonVersion).Drift | Should -BeFalse
    }

    It 'デーモンが止まっている (コマンドが exit 1 で失敗した) なら $null' {
        Mock Invoke-CodexDaemonCommand { $null }
        Get-CodexDaemonVersion | Should -BeNullOrEmpty
    }

    It 'JSON でなければ $null' {
        Mock Invoke-CodexDaemonCommand { 'not json' }
        Get-CodexDaemonVersion | Should -BeNullOrEmpty
    }
}

Describe 'Sync-CodexDaemon' {
    BeforeEach {
        Mock Test-IsElevated { $false }
        Mock Start-Sleep {}
        Mock Write-Host {}
        Mock Write-Info {}
        Mock Write-Warn {}
        Mock Write-Ok {}
        Mock Write-Fail {}
        Mock Read-Host { 'y' }
        Mock Invoke-CodexDaemonCommand {}
        $script:DaemonVersions = @()
        $script:DaemonCalls = 0
        # 呼ばれるたびに $script:DaemonVersions を先頭から返す (尽きたら最後の値を返し続ける)。
        Mock Get-CodexDaemonVersion {
            $i = [Math]::Min($script:DaemonCalls, $script:DaemonVersions.Count - 1)
            $script:DaemonCalls++
            $script:DaemonVersions[$i]
        }
        function New-TestDaemonVersion {
            param([string]$Cli, [string]$App)
            [pscustomobject]@{ Cli = $Cli; App = $App; Drift = [bool]($Cli -and $App -and $Cli -ne $App) }
        }
    }

    It '版が揃っていれば何も聞かない' {
        $script:DaemonVersions = @(New-TestDaemonVersion '0.159.2' '0.159.2')
        Sync-CodexDaemon
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Invoke-CodexDaemonCommand -Times 0 -Exactly
    }

    It 'デーモンが止まっていれば何も聞かない' {
        $script:DaemonVersions = @(New-TestDaemonVersion '0.159.2' '')
        Sync-CodexDaemon
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It '版が取れなければ何も聞かない' {
        $script:DaemonVersions = @($null)
        Sync-CodexDaemon
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It '昇格中は警告だけして入れ替えない' {
        Mock Test-IsElevated { $true }
        $script:DaemonVersions = @(New-TestDaemonVersion '0.159.2' '0.158.0')
        Sync-CodexDaemon
        Should -Invoke Write-Warn -Times 1 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Invoke-CodexDaemonCommand -Times 0 -Exactly
    }

    It '断られたら入れ替えない' {
        Mock Read-Host { 'n' }
        $script:DaemonVersions = @(New-TestDaemonVersion '0.159.2' '0.158.0')
        Sync-CodexDaemon
        Should -Invoke Invoke-CodexDaemonCommand -Times 0 -Exactly
    }

    It '承諾されたら update し、新しいデーモンが答えるまで版を読み直す' {
        $script:DaemonVersions = @(
            (New-TestDaemonVersion '0.159.2' '0.158.0'),
            $null,
            (New-TestDaemonVersion '0.159.2' '0.158.0'),
            (New-TestDaemonVersion '0.159.2' '0.159.2')
        )
        Sync-CodexDaemon
        Should -Invoke Invoke-CodexDaemonCommand -Times 1 -Exactly -ParameterFilter { $Command -eq 'update' }
        Should -Invoke Get-CodexDaemonVersion -Times 4 -Exactly
        Should -Invoke Write-Ok -Times 1 -Exactly
        Should -Invoke Write-Fail -Times 0 -Exactly
    }

    It '入れ替えても版がずれたままなら 5 回読み直して失敗を表示する' {
        $script:DaemonVersions = @(New-TestDaemonVersion '0.159.2' '0.158.0')
        Sync-CodexDaemon
        Should -Invoke Get-CodexDaemonVersion -Times 6 -Exactly
        Should -Invoke Write-Fail -Times 1 -Exactly
        Should -Invoke Write-Ok -Times 0 -Exactly
    }

    It '読み直しても起動しなければ 5 回で諦めて失敗を表示する' {
        $script:DaemonVersions = @((New-TestDaemonVersion '0.159.2' '0.158.0'), $null)
        Sync-CodexDaemon
        Should -Invoke Get-CodexDaemonVersion -Times 6 -Exactly
        Should -Invoke Write-Fail -Times 1 -Exactly
    }
}
