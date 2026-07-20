#requires -Version 5.1
# lib/claude.ps1 を検証する (Pester 5)。claude CLI を叩く関数は副作用の塊なので、
# ここでは出力パース (Get-ClaudePluginVersion) だけを純粋に検証する。
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
