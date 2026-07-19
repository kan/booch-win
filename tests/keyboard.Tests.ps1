#requires -Version 5.1
# lib/keyboard.ps1 を検証する (Pester 5)。Scancode Map のバイト組み立ては純粋関数なので
# 既知の remap → 既知のバイト列で照合する。入力方式まわりは Windows の言語 cmdlet をモックする。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'keyboard.ps1')

    # 実環境に無くてもモックできるよう、同名の関数スタブを先に置く。
    function Get-WinUserLanguageList { }
    function Get-WinDefaultInputMethodOverride { }
}

Describe 'Get-ScancodeMapBytes' {
    It '既知の remap から Scancode Map のバイト列を組み立てる' {
        # CapsLock→Left Ctrl / 右 Alt→かな / 右 Win→かな (拡張キーは上位 0xE0)
        $remaps = @(
            @{ From = 0x003A; To = 0x001D }
            @{ From = 0xE038; To = 0x0070 }
            @{ From = 0xE05C; To = 0x0070 }
        )
        $hex = (Get-ScancodeMapBytes $remaps | ForEach-Object { $_.ToString('X2') }) -join ' '
        $hex | Should -Be '00 00 00 00 00 00 00 00 04 00 00 00 1D 00 3A 00 70 00 38 E0 70 00 5C E0 00 00 00 00'
    }

    It 'マッピング数は実数 + null 終端になる' {
        $bytes = Get-ScancodeMapBytes @(@{ From = 0x003A; To = 0x001D })
        [BitConverter]::ToUInt32($bytes, 8) | Should -Be 2      # 1 件 + null
        $bytes.Length | Should -Be 20                            # 8 + 4 + 4 + 4
    }

    It '空なら $null を返す (remap を管理しない)' {
        Get-ScancodeMapBytes @() | Should -BeNullOrEmpty
        Get-ScancodeMapBytes $null | Should -BeNullOrEmpty
    }
}

Describe 'Test-InputMethodCurrent' {
    It 'tips 一致かつ既定一致なら TipsOk/DefOk とも true' {
        Mock Get-WinUserLanguageList { @([pscustomobject]@{ LanguageTag = 'ja'; InputMethodTips = @('0411:{A}{B}') }) }
        Mock Get-WinDefaultInputMethodOverride { [pscustomobject]@{ InputMethodTip = '0411:{A}{B}' } }
        $r = Test-InputMethodCurrent 'ja' @('0411:{A}{B}')
        $r.TipsOk | Should -BeTrue
        $r.DefOk  | Should -BeTrue
    }

    It '別 IME が混在していれば TipsOk false' {
        Mock Get-WinUserLanguageList { @([pscustomobject]@{ LanguageTag = 'ja'; InputMethodTips = @('0411:{MSIME}', '0411:{A}{B}') }) }
        Mock Get-WinDefaultInputMethodOverride { [pscustomobject]@{ InputMethodTip = '0411:{A}{B}' } }
        (Test-InputMethodCurrent 'ja' @('0411:{A}{B}')).TipsOk | Should -BeFalse
    }

    It '既定入力が別なら DefOk false (override 未設定を含む)' {
        Mock Get-WinUserLanguageList { @([pscustomobject]@{ LanguageTag = 'ja'; InputMethodTips = @('0411:{A}{B}') }) }
        Mock Get-WinDefaultInputMethodOverride { $null }
        (Test-InputMethodCurrent 'ja' @('0411:{A}{B}')).DefOk | Should -BeFalse
    }

    It '対象言語が未追加なら TipsOk false' {
        Mock Get-WinUserLanguageList { @([pscustomobject]@{ LanguageTag = 'en-US'; InputMethodTips = @() }) }
        Mock Get-WinDefaultInputMethodOverride { $null }
        (Test-InputMethodCurrent 'ja' @('0411:{A}{B}')).TipsOk | Should -BeFalse
    }
}
