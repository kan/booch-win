#requires -Version 5.1
# lib/claude.ps1 を検証する (Pester 5)。claude CLI を叩く関数は副作用の塊なので、
# 出力パース (Get-ClaudePluginVersion / Get-ClaudeVersion) と、本体導入の報告分岐
# (Install-ClaudeCode) をスタブで検証する。
# 版の取り違えは「更新されていないのに updated と報告する」等の誤報につながるため、
# ブロック境界の扱いを重点的に見る。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'claude.ps1')

    # claude plugin list の実出力を模した 2 プラグイン分のブロック。
    $script:List = @'
Installed plugins:

  ❯ pike-todo@pike
    Version: 0.2.0
    Scope: user
    Status: ✔ enabled

  ❯ codex@openai-codex
    Version: 1.4.2
    Scope: user
    Status: ✔ enabled
'@

    # 実行時に存在しない可能性のある外部コマンドもモックできるよう関数スタブを置く。
    function claude { }
    function npm { }
}

Describe 'Get-ClaudePluginVersion' {
    It '対象プラグインのブロックから版を読む' {
        Get-ClaudePluginVersion -Plugin 'pike-todo@pike' -PluginList $script:List | Should -Be '0.2.0'
        Get-ClaudePluginVersion -Plugin 'codex@openai-codex' -PluginList $script:List | Should -Be '1.4.2'
    }

    It '未導入のプラグインは空文字を返す' {
        Get-ClaudePluginVersion -Plugin 'nosuch@nowhere' -PluginList $script:List | Should -BeNullOrEmpty
    }

    It 'marketplace 違いの同名プラグインを取り違えない' {
        # 完全一致で照合する (pike-todo@other は別物)。
        Get-ClaudePluginVersion -Plugin 'pike-todo@other' -PluginList $script:List | Should -BeNullOrEmpty
    }

    It 'Version 行を持たないブロックで次のプラグインの版を拾わない' {
        $list = @'
  ❯ broken@mkt
    Status: ✔ enabled

  ❯ codex@openai-codex
    Version: 1.4.2
    Status: ✔ enabled
'@
        Get-ClaudePluginVersion -Plugin 'broken@mkt' -PluginList $list | Should -BeNullOrEmpty
    }

    It 'list を渡さないときは取得しに行き、取れなければ空文字' {
        # 未指定は Get-ClaudePluginList へ委譲する。取得失敗 (claude 未導入・エラー) でも
        # 例外にせず空文字を返す。
        Mock Get-ClaudePluginList { '' }
        Get-ClaudePluginVersion -Plugin 'pike-todo@pike' | Should -BeNullOrEmpty
        Should -Invoke Get-ClaudePluginList -Times 1 -Exactly
    }
}

Describe 'Get-ClaudeVersion' {
    # claude の有無の判断点は Get-ClaudeCommand (実体解決) であって Test-Cmd ではない —
    # あちらは種別を絞らない Get-Command なので、同名の関数・エイリアスがあると未導入でも
    # $true になる。
    It '"2.1.220 (Claude Code)" から版だけを取り出す' {
        Mock Get-ClaudeCommand { 'claude' }
        Mock Invoke-Quiet { "2.1.220 (Claude Code)`r`n" }
        Get-ClaudeVersion | Should -Be '2.1.220'
    }

    It 'claude 未導入なら空文字 (呼びに行かない)' {
        Mock Get-ClaudeCommand { $null }
        Mock Invoke-Quiet { '2.1.220 (Claude Code)' }
        Get-ClaudeVersion | Should -BeNullOrEmpty
        Should -Invoke Invoke-Quiet -Times 0
    }

    It '取得失敗 (空出力) は空文字' {
        Mock Get-ClaudeCommand { 'claude' }
        Mock Invoke-Quiet { '' }
        Get-ClaudeVersion | Should -BeNullOrEmpty
    }

    It '版に見える文字列が無ければ 1 行目をそのまま返す' {
        Mock Get-ClaudeCommand { 'claude' }
        Mock Invoke-Quiet { "unknown`n" }
        Get-ClaudeVersion | Should -Be 'unknown'
    }
}

Describe 'Get-ClaudeCommand / Test-ClaudeInstalled' {
    It '実体を引けなければ未導入と判定する' {
        # 対話プロファイルが claude をラップしている環境では、ベア名解決だと CLI 呼び出しが
        # 関数へ乗っ取られ、Test-Cmd も $true を返してしまう。実体だけを見ることを確かめる。
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'claude' }
        Get-ClaudeCommand | Should -BeNullOrEmpty
        Test-ClaudeInstalled | Should -BeFalse
    }

    It '実体を引ければ導入済みと判定する' {
        Mock Get-Command { 'C:\bin\claude.cmd' } -ParameterFilter { $Name -eq 'claude' }
        Test-ClaudeInstalled | Should -BeTrue
    }
}

Describe 'config dir の切り替え' {
    AfterEach { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }

    It '空文字は「未設定に戻す」(既定 dir を明示設定しない)' {
        $env:CLAUDE_CONFIG_DIR = 'C:\tmp\cfg'
        Set-ClaudeConfigDir ''
        (Test-Path Env:CLAUDE_CONFIG_DIR) | Should -BeFalse
    }

    It '値を渡すと被せる' {
        Set-ClaudeConfigDir 'C:\tmp\cfg'
        $env:CLAUDE_CONFIG_DIR | Should -Be 'C:\tmp\cfg'
    }

    It '空文字の config dir は既定 dir を指す' {
        Get-ClaudeConfigPath '' | Should -Be (Join-Path $HOME '.claude')
        Get-ClaudeConfigPath 'C:\tmp\cfg' | Should -Be 'C:\tmp\cfg'
    }

    It 'Invoke-WithClaudeConfigDir は実行後に呼び出し元の値へ戻す' {
        $env:CLAUDE_CONFIG_DIR = 'C:\tmp\outer'
        $seen = Invoke-WithClaudeConfigDir -ConfigDir 'C:\tmp\inner' -Script { $env:CLAUDE_CONFIG_DIR }
        $seen | Should -Be 'C:\tmp\inner'
        $env:CLAUDE_CONFIG_DIR | Should -Be 'C:\tmp\outer'
    }

    It 'Invoke-WithClaudeConfigDir は未設定だった環境を未設定へ戻す' {
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        Invoke-WithClaudeConfigDir -ConfigDir 'C:\tmp\inner' -Script { } | Out-Null
        (Test-Path Env:CLAUDE_CONFIG_DIR) | Should -BeFalse
    }
}

Describe 'Install-ClaudeCode' {
    BeforeEach {
        $script:Ok = @()
        Mock Write-Ok { $script:Ok += $Msg }
        Mock Write-Info { }
        Mock Write-Fail { $script:Ok += "FAIL: $Msg" }
        Mock Write-Warn { $script:Ok += "WARN: $Msg" }
        # 既定は claude 未実行 (npm フォールバックが走れる状態)。
        Mock Get-ClaudeProcess { @() }
        # update / npm は呼ばない。$LASTEXITCODE を 0 にして npm フォールバックへ落ちないようにする。
        Mock Invoke-Quiet { $global:LASTEXITCODE = 0 }
        Mock npm { $global:LASTEXITCODE = 0 }
    }

    It '版が上がれば updated (old -> new) を報告する' {
        Mock Get-ClaudeCommand { 'claude' }
        Mock Test-Cmd { $true }   # npm あり
        $script:n = 0
        Mock Get-ClaudeVersion { $script:n++; if ($script:n -eq 1) { '2.1.195' } else { '2.1.220' } }
        Install-ClaudeCode
        $script:Ok | Should -Be @('Claude Code: updated (2.1.195 -> 2.1.220)')
    }

    It '版が変わらなければ already installed (版) を報告する' {
        Mock Get-ClaudeCommand { 'claude' }
        Mock Test-Cmd { $true }   # npm あり
        Mock Get-ClaudeVersion { '2.1.220' }
        Install-ClaudeCode
        $script:Ok | Should -Be @('Claude Code: already installed (2.1.220)')
    }

    It 'claude update が失敗したら npm でグローバル更新する' {
        Mock Get-ClaudeCommand { 'claude' }
        Mock Test-Cmd { $true }   # npm あり
        Mock Invoke-Quiet { $global:LASTEXITCODE = 1 }
        Mock Get-ClaudeVersion { '2.1.220' }
        Install-ClaudeCode
        Should -Invoke npm -Times 1
    }

    It 'claude 実行中は npm フォールバックを走らせず警告する' {
        # npm はグローバル更新の前に既存パッケージを退避コピーするため、実行中の
        # claude.exe があると EBUSY で必ず落ちる。生のエラーを出さずスキップする。
        Mock Get-ClaudeCommand { 'claude' }
        Mock Test-Cmd { $true }   # npm あり
        Mock Invoke-Quiet { $global:LASTEXITCODE = 1 }
        Mock Get-ClaudeVersion { '2.1.220' }
        Mock Get-ClaudeProcess { @('proc1', 'proc2') }
        Install-ClaudeCode
        Should -Invoke npm -Times 0
        $script:Ok[0] | Should -BeLike 'WARN: Claude Code: 実行中 (2 プロセス)*'
    }

    It '未導入からの導入は installed (版) を報告する' {
        Mock Get-ClaudeCommand { $null }   # claude 無し
        Mock Test-Cmd { $true }            # npm あり
        Mock Get-ClaudeVersion { '2.1.220' }
        Install-ClaudeCode
        Should -Invoke npm -Times 1
        $script:Ok | Should -Be @('Claude Code: installed (2.1.220)')
    }
}
