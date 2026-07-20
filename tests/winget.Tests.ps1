#requires -Version 5.1
# lib/winget.ps1 を検証する (Pester 5)。winget.exe を叩く関数は副作用の塊なので、
# ここでは終了コードの分類 (Test-WingetUpgradeNoop) だけを純粋に検証する。
# ここを取り違えると「更新の失敗を毎回無視する」か「最新のたびに警告を出す」の
# どちらかになるため、境界を明示的に固定しておく。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
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
