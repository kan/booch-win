#requires -Version 5.1
# lib/winget.ps1 を検証する (Pester 5)。winget.exe を実際に叩く部分 (Invoke-WingetRead) は
# 副作用の塊なので seam として mock し、その戻り値をどう解釈するか — 終了コードの分類
# (Test-WingetUpgradeNoop)、3 値の導入判定 (Get-WingetInstallState)、判定不能時の
# skip (Install-WingetPackages) — を純粋に検証する。
# ここを取り違えると「更新の失敗を毎回無視する」か「最新のたびに警告を出す」、あるいは
# 「応答が返らない winget を無限に待つ」のいずれかになるため、境界を明示的に固定しておく。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')    # Get-EffectiveTimeout (Get-WingetReadTimeout が使う)
    . (Join-Path $lib 'winget.ps1')
}

Describe 'Test-WingetUpgradeNoop' {
    It '0 は成功 (実際に更新した)' {
        Test-WingetUpgradeNoop 0 | Should -BeTrue
    }

    It '0x8A15002B (適用できる更新が無い) は失敗としない' {
        # 最新のパッケージへ upgrade をかけると毎回これが返る。
        Test-WingetUpgradeNoop -1978335189 | Should -BeTrue
    }

    It 'ID を解決できない等の別コードは失敗として扱う' {
        # 0x8A150014: 条件に一致するパッケージが見つからない。追跡 ID が winget ソースと
        # 相関できていない状態なので、隠さず可視化したい。
        Test-WingetUpgradeNoop -1978335212 | Should -BeFalse
    }

    It '未知の非 0 は失敗として扱う' {
        Test-WingetUpgradeNoop 1 | Should -BeFalse
        Test-WingetUpgradeNoop -1 | Should -BeFalse
    }
}

Describe 'Get-WingetReadTimeout' {
    AfterEach {
        Remove-Variable -Name WingetReadTimeoutSec -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name DisableTimeout       -Scope Script -ErrorAction SilentlyContinue
    }

    It 'エントリ側が何も定義していなければ既定の 60 秒' {
        Get-WingetReadTimeout | Should -Be 60
    }

    It 'エントリ側の $Script:WingetReadTimeoutSec を優先する' {
        $Script:WingetReadTimeoutSec = 5
        Get-WingetReadTimeout | Should -Be 5
    }

    It '--no-timeout ($Script:DisableTimeout) では 0 (無制限) を返す' {
        $Script:WingetReadTimeoutSec = 5
        $Script:DisableTimeout = $true
        Get-WingetReadTimeout | Should -Be 0
    }
}

Describe 'Invoke-WingetRead (実プロセス)' {
    # ここだけは seam を挟まず実プロセスを起動する。終了コードを取れるかどうかは
    # Start-Process の使い方そのものに依存していて、Invoke-WingetRead を mock した
    # 契約テストでは絶対に捕まらないため (実際、リダイレクト併用で ExitCode が $null に
    # なり、[int] キャストで 0 = 成功へ化ける回帰を実機まで検出できなかった)。
    # winget.exe は CI にも開発機にも無いことがあるので cmd.exe で代用する。

    It 'リダイレクトを併用しても非 0 の終了コードを取り落とさない' {
        $r = Invoke-WingetRead -FilePath 'cmd.exe' -WingetArgs @('/c', 'exit 3')
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be 3
    }

    It '成功 (exit 0) と失敗を取り違えない' {
        $r = Invoke-WingetRead -FilePath 'cmd.exe' -WingetArgs @('/c', 'exit 0')
        $r.ExitCode | Should -Be 0
    }

    It '上限を超えたら TimedOut で、終了コードは名乗らない' {
        $r = Invoke-WingetRead -FilePath 'cmd.exe' -WingetArgs @('/c', 'ping -n 20 127.0.0.1') -TimeoutSec 1
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -BeNullOrEmpty
    }

    It '起動できなければ ExitCode は $null (0 へ丸めない)' {
        $r = Invoke-WingetRead -FilePath 'booch-win-no-such-exe.exe' -WingetArgs @('--version')
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -BeNullOrEmpty
    }
}

Describe 'Get-WingetInstallState' {
    It 'exit 0 は Installed' {
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = 0 } }
        Get-WingetInstallState 'Foo.Bar' | Should -Be 'Installed'
    }

    It '非 0 は NotInstalled' {
        # NO_APPLICATIONS_FOUND。未導入の通常経路。
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = -1978335212 } }
        Get-WingetInstallState 'Foo.Bar' | Should -Be 'NotInstalled'
    }

    It 'タイムアウトは Unknown (未導入へ丸めない)' {
        Mock Invoke-WingetRead { @{ TimedOut = $true; ExitCode = $null } }
        Get-WingetInstallState 'Foo.Bar' | Should -Be 'Unknown'
    }

    It '起動失敗 (winget.exe が無い) も Unknown' {
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = $null } }
        Get-WingetInstallState 'Foo.Bar' | Should -Be 'Unknown'
    }

    It '省略時は Get-WingetReadTimeout の値を渡す' {
        Mock Get-WingetReadTimeout { 42 }
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = 0 } }
        Get-WingetInstallState 'Foo.Bar' | Out-Null
        Should -Invoke Invoke-WingetRead -Times 1 -ParameterFilter { $TimeoutSec -eq 42 }
    }

    It '明示した TimeoutSec はそのまま使う' {
        Mock Get-WingetReadTimeout { 42 }
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = 0 } }
        Get-WingetInstallState 'Foo.Bar' -TimeoutSec 7 | Out-Null
        Should -Invoke Invoke-WingetRead -Times 1 -ParameterFilter { $TimeoutSec -eq 7 }
    }
}

Describe 'Get-WingetInstalledIds' {
    It 'export した JSON から PackageIdentifier を集める' {
        Mock Invoke-WingetRead {
            # 実物と同じく -o の次の引数が出力先。mock 側でそこへ JSON を置く。
            $out = $WingetArgs[[array]::IndexOf($WingetArgs, '-o') + 1]
            $json = '{"Sources":[{"Packages":[{"PackageIdentifier":"Foo.Bar"},{"PackageIdentifier":"Baz.Qux"}]}]}'
            Set-Content -LiteralPath $out -Value $json -Encoding UTF8
            @{ TimedOut = $false; ExitCode = 0 }
        }
        $ids = Get-WingetInstalledIds
        $ids | Should -Be @('Foo.Bar', 'Baz.Qux')
    }

    It 'タイムアウトなら空配列 (途中まで書かれた JSON を読まない)' {
        Mock Invoke-WingetRead {
            $out = $WingetArgs[[array]::IndexOf($WingetArgs, '-o') + 1]
            Set-Content -LiteralPath $out -Value '{"Sources":[{"Packages":[{"PackageIdentifier":"Foo.Bar"}' -Encoding UTF8
            @{ TimedOut = $true; ExitCode = $null }
        }
        @(Get-WingetInstalledIds).Count | Should -Be 0
    }

    It '起動失敗なら空配列' {
        Mock Invoke-WingetRead { @{ TimedOut = $false; ExitCode = $null } }
        @(Get-WingetInstalledIds).Count | Should -Be 0
    }
}

Describe 'Install-WingetPackages' {
    BeforeEach {
        Mock Write-Host {}; Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}; Mock Write-Fail {}
        Mock Invoke-Winget { 0 }
    }

    It '導入済みなら upgrade を呼ぶ' {
        Mock Get-WingetInstallState { 'Installed' }
        Install-WingetPackages -Packages @(@{ Id = 'Foo.Bar'; Cmd = 'foo' })
        Should -Invoke Invoke-Winget -Times 1 -ParameterFilter { $WingetArgs[0] -eq 'upgrade' }
    }

    It '未導入なら install を呼ぶ' {
        Mock Get-WingetInstallState { 'NotInstalled' }
        Install-WingetPackages -Packages @(@{ Id = 'Foo.Bar'; Cmd = 'foo' })
        Should -Invoke Invoke-Winget -Times 1 -ParameterFilter { $WingetArgs[0] -eq 'install' }
    }

    It '判定不能なら winget を一切叩かず警告して次へ進む' {
        Mock Get-WingetInstallState { if ($Id -eq 'Slow.One') { 'Unknown' } else { 'NotInstalled' } }
        Install-WingetPackages -Packages @(
            @{ Id = 'Slow.One'; Cmd = 'slow' },
            @{ Id = 'Foo.Bar';  Cmd = 'foo' }
        )
        # skip したパッケージでは install も upgrade も走らない (= 呼び出しは後続の 1 回だけ)。
        Should -Invoke Invoke-Winget -Times 1
        Should -Invoke Invoke-Winget -Times 1 -ParameterFilter { $WingetArgs -contains 'Foo.Bar' }
        # skip は黙って起きない (次回の実行で拾う旨をログに残す)。
        Should -Invoke Write-Warn -Times 1 -ParameterFilter { $Msg -like '*Slow.One*' }
    }

    It 'Optional は未導入なら install しない (入っている環境だけ更新する宣言)' {
        Mock Get-WingetInstallState { 'NotInstalled' }
        Install-WingetPackages -Packages @(@{ Id = 'Heavy.Sdk'; Cmd = 'heavy'; Optional = $true })
        Should -Invoke Invoke-Winget -Times 0
        # 意図的な skip であることをログに残す (宣言したのに入らない、と読めないように)。
        Should -Invoke Write-Info -Times 1 -ParameterFilter { $Msg -like '*Heavy.Sdk*' }
    }

    It 'Optional でも導入済みなら upgrade を呼ぶ' {
        Mock Get-WingetInstallState { 'Installed' }
        Install-WingetPackages -Packages @(@{ Id = 'Heavy.Sdk'; Cmd = 'heavy'; Optional = $true })
        Should -Invoke Invoke-Winget -Times 1 -ParameterFilter { $WingetArgs[0] -eq 'upgrade' }
    }

    It 'Optional を指定しないパッケージは従来どおり install する' {
        Mock Get-WingetInstallState { 'NotInstalled' }
        Install-WingetPackages -Packages @(
            @{ Id = 'Heavy.Sdk'; Cmd = 'heavy'; Optional = $false },
            @{ Id = 'Foo.Bar';   Cmd = 'foo' }
        )
        Should -Invoke Invoke-Winget -Times 2 -ParameterFilter { $WingetArgs[0] -eq 'install' }
    }
}

Describe 'Merge-WingetSettingsJson' {
    It '空のテキストからでも指定キーだけの settings を組み立てる' {
        $r = Merge-WingetSettingsJson -Json '' -Settings ([ordered]@{
            installBehavior = [ordered]@{ downloader = 'wininet' } })
        $r.Changed | Should -BeTrue
        ($r.Json | ConvertFrom-Json).installBehavior.downloader | Should -Be 'wininet'
    }

    It '既存の他キーを壊さない (ユーザーが winget settings で書いた設定を保つ)' {
        $json = '{"$schema":"https://aka.ms/winget-settings.schema.json","visual":{"progressBar":"rainbow"},"installBehavior":{"preferences":{"scope":"user"}}}'
        $r = Merge-WingetSettingsJson -Json $json -Settings ([ordered]@{
            installBehavior = [ordered]@{ downloader = 'wininet' } })
        $o = $r.Json | ConvertFrom-Json
        $o.visual.progressBar | Should -Be 'rainbow'
        $o.installBehavior.preferences.scope | Should -Be 'user'   # 兄弟キーは残る
        $o.installBehavior.downloader | Should -Be 'wininet'
        $o.'$schema' | Should -Be 'https://aka.ms/winget-settings.schema.json'
    }

    It '同じ値がすでに入っていれば Changed=false (無用な書き戻しをしない)' {
        $json = '{"installBehavior":{"downloader":"wininet"}}'
        $r = Merge-WingetSettingsJson -Json $json -Settings ([ordered]@{
            installBehavior = [ordered]@{ downloader = 'wininet' } })
        $r.Changed | Should -BeFalse
    }

    It '整形 (インデント・改行) の違いだけでは Changed にしない' {
        $json = "{`n    `"installBehavior`": {`n        `"downloader`":  `"wininet`"`n    }`n}`n"
        $r = Merge-WingetSettingsJson -Json $json -Settings ([ordered]@{
            installBehavior = [ordered]@{ downloader = 'wininet' } })
        $r.Changed | Should -BeFalse
    }

    It '値が違えば上書きする' {
        $json = '{"installBehavior":{"downloader":"do"}}'
        $r = Merge-WingetSettingsJson -Json $json -Settings ([ordered]@{
            installBehavior = [ordered]@{ downloader = 'wininet' } })
        $r.Changed | Should -BeTrue
        ($r.Json | ConvertFrom-Json).installBehavior.downloader | Should -Be 'wininet'
    }

    It '既存がスカラーで新しい値がオブジェクトなら置き換える (型の食い違いを残さない)' {
        $json = '{"installBehavior":"broken"}'
        $r = Merge-WingetSettingsJson -Json $json -Settings ([ordered]@{
            installBehavior = [ordered]@{ downloader = 'wininet' } })
        ($r.Json | ConvertFrom-Json).installBehavior.downloader | Should -Be 'wininet'
    }

    It '配列は要素をマージせず丸ごと置き換える' {
        $json = '{"network":{"downloader":"do"},"experimentalFeatures":["a","b"]}'
        $r = Merge-WingetSettingsJson -Json $json -Settings ([ordered]@{ experimentalFeatures = @('c') })
        $o = $r.Json | ConvertFrom-Json
        @($o.experimentalFeatures) | Should -Be @('c')
    }

    It 'BOM 付きのテキストでも読める' {
        $json = [char]0xFEFF + '{"installBehavior":{"downloader":"do"}}'
        $r = Merge-WingetSettingsJson -Json $json -Settings ([ordered]@{
            installBehavior = [ordered]@{ downloader = 'wininet' } })
        $r.Changed | Should -BeTrue
    }

    It '壊れた JSON は投げる (呼び出し側に触らせない)' {
        { Merge-WingetSettingsJson -Json '{ "installBehavior": ' -Settings ([ordered]@{ a = 1 }) } |
            Should -Throw
    }

    It 'コメント付き (JSONC) も投げる — 読める版でも書き戻してコメントを消さない' {
        # winget は settings.json のコメントを許す。PS7 の ConvertFrom-Json はこれを読めて
        # しまうので、そのまま通すと再直列化でコメントが落ちる (PS5.1 では例外)。版で挙動が
        # 分かれないよう、実装側で明示的に弾いている。
        $json = @"
{
    // 既定の downloader を上書きしている
    "installBehavior": { "downloader": "do" }
}
"@
        { Merge-WingetSettingsJson -Json $json -Settings ([ordered]@{ a = 1 }) } | Should -Throw
    }

    It '値の中の URL (//) はコメントと誤検出しない' {
        $json = '{"$schema":"https://aka.ms/winget-settings.schema.json"}'
        $r = Merge-WingetSettingsJson -Json $json -Settings ([ordered]@{ a = 'b' })
        ($r.Json | ConvertFrom-Json).'$schema' | Should -Be 'https://aka.ms/winget-settings.schema.json'
    }

    It 'トップレベルがオブジェクトでなければ投げる' {
        { Merge-WingetSettingsJson -Json '[1,2]' -Settings ([ordered]@{ a = 1 }) } | Should -Throw
    }
}

Describe 'Update-WingetSettings' {
    BeforeEach {
        $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('booch-win-winget-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:tmpDir | Out-Null
        $script:tmp = Join-Path $script:tmpDir 'settings.json'
    }
    AfterEach {
        Remove-Item $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '無ければ親ディレクトリごと作って書く' {
        $nested = Join-Path $script:tmpDir 'LocalState\settings.json'
        Update-WingetSettings -Path $nested -Settings ([ordered]@{
            installBehavior = [ordered]@{ downloader = 'wininet' } })
        (Get-Content $nested -Raw | ConvertFrom-Json).installBehavior.downloader | Should -Be 'wininet'
    }

    It 'BOM 無し UTF-8 で書く' {
        Update-WingetSettings -Path $script:tmp -Settings ([ordered]@{ a = 'b' })
        $bytes = [IO.File]::ReadAllBytes($script:tmp)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }

    It '変更が無ければファイルに触らない' {
        [IO.File]::WriteAllText($script:tmp, '{"installBehavior":{"downloader":"wininet"}}')
        $before = (Get-Item $script:tmp).LastWriteTimeUtc
        Start-Sleep -Milliseconds 20
        Update-WingetSettings -Path $script:tmp -Settings ([ordered]@{
            installBehavior = [ordered]@{ downloader = 'wininet' } })
        (Get-Item $script:tmp).LastWriteTimeUtc | Should -Be $before
    }

    It '読めない JSON は書き換えず、内容をそのまま残す' {
        $broken = '{ "installBehavior": '
        [IO.File]::WriteAllText($script:tmp, $broken)
        Update-WingetSettings -Path $script:tmp -Settings ([ordered]@{ a = 'b' })
        [IO.File]::ReadAllText($script:tmp) | Should -Be $broken
    }
}
