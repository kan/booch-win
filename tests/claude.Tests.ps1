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
    It '"2.1.220 (Claude Code)" から版だけを取り出す' {
        Mock Test-Cmd { $true }
        Mock Invoke-Quiet { "2.1.220 (Claude Code)`r`n" }
        Get-ClaudeVersion | Should -Be '2.1.220'
    }

    It 'claude 未導入なら空文字 (呼びに行かない)' {
        Mock Test-Cmd { $false }
        Mock Invoke-Quiet { '2.1.220 (Claude Code)' }
        Get-ClaudeVersion | Should -BeNullOrEmpty
        Should -Invoke Invoke-Quiet -Times 0
    }

    It '取得失敗 (空出力) は空文字' {
        Mock Test-Cmd { $true }
        Mock Invoke-Quiet { '' }
        Get-ClaudeVersion | Should -BeNullOrEmpty
    }

    It '版に見える文字列が無ければ 1 行目をそのまま返す' {
        Mock Test-Cmd { $true }
        Mock Invoke-Quiet { "unknown`n" }
        Get-ClaudeVersion | Should -Be 'unknown'
    }
}

Describe 'Install-ClaudeCode' {
    BeforeEach {
        $script:Ok = @()
        Mock Write-Ok { $script:Ok += $Msg }
        Mock Write-Info { }
        Mock Write-Fail { $script:Ok += "FAIL: $Msg" }
        # update / npm は呼ばない。$LASTEXITCODE を 0 にして npm フォールバックへ落ちないようにする。
        Mock Invoke-Quiet { $global:LASTEXITCODE = 0 }
        Mock npm { $global:LASTEXITCODE = 0 }
    }

    It '版が上がれば updated (old -> new) を報告する' {
        Mock Test-Cmd { $true }
        $script:n = 0
        Mock Get-ClaudeVersion { $script:n++; if ($script:n -eq 1) { '2.1.195' } else { '2.1.220' } }
        Install-ClaudeCode
        $script:Ok | Should -Be @('Claude Code: updated (2.1.195 -> 2.1.220)')
    }

    It '版が変わらなければ already installed (版) を報告する' {
        Mock Test-Cmd { $true }
        Mock Get-ClaudeVersion { '2.1.220' }
        Install-ClaudeCode
        $script:Ok | Should -Be @('Claude Code: already installed (2.1.220)')
    }

    It '未導入からの導入は installed (版) を報告する' {
        Mock Test-Cmd { param($Name) $Name -eq 'npm' }   # claude 無し / npm あり
        Mock Get-ClaudeVersion { '2.1.220' }
        Install-ClaudeCode
        Should -Invoke npm -Times 1
        $script:Ok | Should -Be @('Claude Code: installed (2.1.220)')
    }
}
