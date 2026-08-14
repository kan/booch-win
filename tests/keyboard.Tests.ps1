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

Describe 'Get-InputMethodTipId' {
    It 'TIP 文字列を言語 ID / CLSID / プロファイルに分解する' {
        $id = Get-InputMethodTipId '0411:{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}{956F14B3-5310-4CEF-9651-26710EB72F3A}'
        # LangKey は CTF\TIP の下のキー名 (8 桁ゼロ埋め) であって、TIP 文字列の 4 桁ではない。
        $id.LangKey | Should -Be '0x00000411'
        $id.Clsid   | Should -Be '{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}'
        $id.Profile | Should -Be '{956F14B3-5310-4CEF-9651-26710EB72F3A}'
    }

    It '形が違う TIP 文字列は $null を返す (例外にしない)' {
        Get-InputMethodTipId ''          | Should -BeNullOrEmpty
        Get-InputMethodTipId 'CorvusSKK' | Should -BeNullOrEmpty
        # プロファイル GUID を欠く (CLSID だけ) のも不正。
        Get-InputMethodTipId '0411:{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}' | Should -BeNullOrEmpty
    }
}

Describe 'Get-InputMethodTipRegistryPath' {
    It '64bit / 32bit の CLSID は別ビューを見る' {
        $id = Get-InputMethodTipId '0411:{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}{956F14B3-5310-4CEF-9651-26710EB72F3A}'
        $p = Get-InputMethodTipRegistryPath -Id $id
        $p.Server64 | Should -Be 'HKLM:\SOFTWARE\Classes\CLSID\{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}\InProcServer32'
        $p.Server32 | Should -Be 'HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}\InProcServer32'
        $p.Profile  | Should -Be 'HKLM:\SOFTWARE\Microsoft\CTF\TIP\{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}\LanguageProfile\0x00000411\{956F14B3-5310-4CEF-9651-26710EB72F3A}'
    }
}

Describe 'Get-InputMethodTipProblem' {
    BeforeEach {
        # 「全部正常」の状態。各 It はここから 1 箇所だけ壊して指摘を確かめる。
        $script:healthy = @{
            Dll64    = $true
            Dll32    = $true
            Server64 = 'C:\WINDOWS\system32\IME\IMCRVSKK\imcrvtip.dll'
            Server32 = 'C:\WINDOWS\SysWow64\IME\IMCRVSKK\imcrvtip.dll'
            Profile  = $true
            Enabled  = $true
        }
    }

    It '全部揃っていれば問題なしを返す' {
        @(Get-InputMethodTipProblem -State $script:healthy).Count | Should -Be 0
    }

    It 'COM 登録が消えていれば 64bit / 32bit それぞれを指摘する' {
        $s = $script:healthy.Clone()
        $s.Server64 = $null
        $s.Server32 = $null
        $m = @(Get-InputMethodTipProblem -State $s)
        $m.Count | Should -Be 2
        ($m -join ' ') | Should -Match '64bit'
        ($m -join ' ') | Should -Match 'WOW6432Node'
    }

    It '導入されていない版の登録は要求しない (32bit だけ無い機)' {
        $s = $script:healthy.Clone()
        $s.Dll32 = $false
        $s.Server32 = $null
        @(Get-InputMethodTipProblem -State $s).Count | Should -Be 0
    }

    It '言語プロファイルが無い / 無効なら指摘する' {
        $s = $script:healthy.Clone()
        $s.Profile = $false
        $s.Enabled = $false
        (@(Get-InputMethodTipProblem -State $s) -join ' ') | Should -Match 'LanguageProfile'

        $s2 = $script:healthy.Clone()
        $s2.Enabled = $false
        (@(Get-InputMethodTipProblem -State $s2) -join ' ') | Should -Match 'Enable=0'
    }

    It '状態を読めなければその旨を返す' {
        @(Get-InputMethodTipProblem -State $null).Count | Should -Be 1
    }
}

Describe 'Test-InputMethodTipInstalled' {
    It 'DLL が 1 つも無ければ未導入として扱う' {
        $s = @{ Dll64 = $false; Dll32 = $false }
        Test-InputMethodTipInstalled -State $s | Should -BeFalse
        Test-InputMethodTipInstalled -State @{ Dll64 = $true; Dll32 = $false } | Should -BeTrue
        Test-InputMethodTipInstalled -State $null | Should -BeFalse
    }
}

Describe 'Test-InputMethodTipMissing' {
    It 'どちらのビューにも COM 登録が無ければ true' {
        Test-InputMethodTipMissing @{ Server64 = $null; Server32 = $null; Enabled = $true } | Should -BeTrue
    }

    It '片方のビューにでも登録があり、プロファイルが有効なら false' {
        # DLL の所在を知らない弱い判定なので、片側だけ消えた状態は拾わない (それは
        # Get-InputMethodTipProblem の担当)。
        Test-InputMethodTipMissing @{ Server64 = 'x.dll'; Server32 = $null; Enabled = $true } | Should -BeFalse
    }

    It '言語プロファイルが無効なら true' {
        Test-InputMethodTipMissing @{ Server64 = 'x.dll'; Server32 = 'x.dll'; Enabled = $false } | Should -BeTrue
    }

    It '状態を読めなければ true' {
        Test-InputMethodTipMissing $null | Should -BeTrue
    }
}

Describe 'Set-InputMethod' {
    BeforeEach {
        Mock Write-Ok {}; Mock Write-Info {}; Mock Write-Warn {}
        $script:Tip = '0411:{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}{956F14B3-5310-4CEF-9651-26710EB72F3A}'
    }

    It '設定済みでも TIP の登録が無ければ警告する' {
        # 設定 (言語一覧) は正しいのに入力できない状態。早期 return でここを素通りすると、
        # 「設定は正しいのに日本語入力が丸ごと死ぬ」を誰も検出できなくなる。
        Mock Test-InputMethodCurrent { @{ TipsOk = $true; DefOk = $true } }
        Mock Get-InputMethodTipState { @{ Server64 = $null; Server32 = $null; Enabled = $false } }
        Set-InputMethod 'ja' @($script:Tip)
        Should -Invoke Write-Warn -Times 1
    }

    It '設定済みで登録もあれば警告しない' {
        Mock Test-InputMethodCurrent { @{ TipsOk = $true; DefOk = $true } }
        Mock Get-InputMethodTipState { @{ Server64 = 'x.dll'; Server32 = 'x.dll'; Enabled = $true } }
        Set-InputMethod 'ja' @($script:Tip)
        Should -Invoke Write-Warn -Times 0
    }

    It 'TIP 文字列として解釈できなければ登録は見ない (警告もしない)' {
        Mock Test-InputMethodCurrent { @{ TipsOk = $true; DefOk = $true } }
        Mock Get-InputMethodTipState { throw '呼ばれてはいけない' }
        Set-InputMethod 'ja' @('CorvusSKK')
        Should -Invoke Write-Warn -Times 0
    }
}

Describe 'Test-InputMethodTipRegistered' {
    It '形が違う TIP 文字列は false (レジストリを読まない)' {
        Mock Get-InputMethodTipState { throw '呼ばれてはいけない' }
        Test-InputMethodTipRegistered -Tip 'CorvusSKK' | Should -BeFalse
    }

    It 'DLL の所在を渡せば、その版の登録だけを要求する' {
        Mock Get-InputMethodTipState {
            @{ Dll64 = $Dll64; Dll32 = $Dll32; Server64 = 'x.dll'; Server32 = $null
               Profile = $true; Enabled = $true }
        }
        $tip = '0411:{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}{956F14B3-5310-4CEF-9651-26710EB72F3A}'
        Test-InputMethodTipRegistered -Tip $tip -Dll64 $true -Dll32 $false | Should -BeTrue
        Test-InputMethodTipRegistered -Tip $tip -Dll64 $true -Dll32 $true  | Should -BeFalse
    }

    It 'DLL の所在を渡さなければ弱い判定になる (片側だけの登録でも true)' {
        Mock Get-InputMethodTipState {
            @{ Dll64 = $false; Dll32 = $false; Server64 = 'x.dll'; Server32 = $null
               Profile = $true; Enabled = $true }
        }
        Test-InputMethodTipRegistered -Tip '0411:{EAEA0E29-AA1E-48EF-B2DF-46F4E24C6265}{956F14B3-5310-4CEF-9651-26710EB72F3A}' |
            Should -BeTrue
    }
}
