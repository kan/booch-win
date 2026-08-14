#Requires -Version 5.1
#
# lib/keyboard.ps1: 汎用機構 — キーボード remap (Scancode Map) と入力方式 (TSF) の設定
#
# dotfiles-win.ps1 から dot-source される。どのキーを入れ替えるか / どの入力方式にするかは
# 個人選択なので消費側の config が持ち、ここは適用・判定の「やり方」だけを提供する。
#
# 公開 API:
#   Get-ScancodeMapBytes(Remaps)                remap 一覧から Scancode Map のバイト列を組み立てる
#   Test-ScancodeMapCurrent(Want)               現在のレジストリ値が Want と一致するか
#   Set-ScancodeMap(Remaps)                     Scancode Map を適用する (HKLM。管理者権限が要る)
#   Test-InputMethodCurrent(LanguageTag Tips)   入力方式と既定入力が Tips どおりか
#   Set-InputMethod(LanguageTag Tips)           入力方式を Tips 単独にし既定を Tips[0] に固定する
#   Get-InputMethodTipId(Tip)                   TIP 文字列を言語 ID / CLSID / プロファイルへ分解
#   Get-InputMethodTipRegistryPath(Id)          TIP の登録を見るレジストリパス
#   Get-InputMethodTipState(Id Dll64 Dll32)     登録の実体を読む (良し悪しは決めない)
#   Test-InputMethodTipInstalled(State)         TIP の DLL がひとつでも在るか
#   Get-InputMethodTipProblem(State)            State から不整合の理由一覧を返す (純粋関数)
#   Test-InputMethodTipMissing(State)           DLL の所在を知らなくても使える弱い判定
#   Test-InputMethodTipRegistered(Tip ...)      TIP が使える形で登録されているか
#
# 「設定」(Test-InputMethodCurrent) と「登録の実体」(Test-InputMethodTipRegistered) は
# 別物なので、両方を見る必要がある。設定が指す TIP の実体が消えていても言語一覧には
# TIP 文字列が残るため、設定だけを見ていると「正常なのに日本語入力が丸ごと死ぬ」状態を
# 検出できない (IME 本体を使用中に upgrade すると、インストーラーが COM 登録を次回ログオンへ
# 先送りする・旧版のアンインストーラーが同じ CLSID の登録を消していく、で実際に起きる)。
#
# 修復 (regsvr32 で DllRegisterServer を呼び直す) はここに持たない。TIP DLL の場所が IME
# 実装ごとに違うので、booch-win は判定まで、入れ直しは消費側が担う。

$Script:BoochWinScancodeMapKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'

# remap 一覧 (@{ From=<scancode>; To=<scancode>; Label=<任意> } の配列) から Scancode Map の
# バイト列を組み立てる。形式: 8B ヘッダ(0) + 4B マッピング数(実数+null) + 各 4B [To(WORD LE)]
# [From(WORD LE)] + 4B null 終端。拡張キーは上位に 0xE0 を持つ (例: 右 Alt = 0xE038)。
# 空なら $null を返す (= remap を管理しない)。
function Get-ScancodeMapBytes { # Remaps
    param([array]$Remaps)
    if (-not $Remaps -or $Remaps.Count -eq 0) { return $null }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.AddRange([byte[]]::new(8))                                            # 8B ヘッダ(0)
    $bytes.AddRange([BitConverter]::GetBytes([uint32]($Remaps.Count + 1)))       # 実数 + null 終端
    foreach ($m in $Remaps) {
        $bytes.AddRange([BitConverter]::GetBytes([uint16]$m.To))
        $bytes.AddRange([BitConverter]::GetBytes([uint16]$m.From))
    }
    $bytes.AddRange([byte[]]::new(4))                                            # 4B null 終端
    return $bytes.ToArray()
}

# 現在の Scancode Map が $Want と一致するか。byte 列は順序が意味を持つので join して比較する。
function Test-ScancodeMapCurrent { # Want
    param([byte[]]$Want)
    $cur = (Get-ItemProperty $Script:BoochWinScancodeMapKey -Name 'Scancode Map' -ErrorAction SilentlyContinue).'Scancode Map'
    return ($cur -and (($cur -join ',') -eq ($Want -join ',')))
}

# Scancode Map を $Remaps の状態へ。差分があれば書き込む。冪等。HKLM なので管理者権限が要り、
# 非管理者なら警告して何もしない。反映には再起動が要る。Label があれば適用内容として表示する。
function Set-ScancodeMap { # Remaps
    param([array]$Remaps)
    $want = Get-ScancodeMapBytes $Remaps
    if ($null -eq $want) { return }
    if (Test-ScancodeMapCurrent $want) { Write-Ok 'キーボード remap (Scancode Map) は最新'; return }
    if (-not (Test-IsElevated)) {
        Write-Warn 'キーボード remap は管理者権限が要ります (昇格して再実行してください)'
        return
    }
    Set-ItemProperty $Script:BoochWinScancodeMapKey -Name 'Scancode Map' -Value $want -Type Binary
    Write-Ok 'キーボード remap (Scancode Map) を適用しました (再起動で有効)'
    foreach ($m in $Remaps) { if ($m.Label) { Write-Info $m.Label } }
}

# $LanguageTag の入力方式が $Tips 単独か (TipsOk) と、既定入力方式が $Tips[0] か (DefOk) を返す。
# 適用 (Set-InputMethod) と診断 (消費側 doctor) が同じ判定を共有するための seam。
function Test-InputMethodCurrent { # LanguageTag Tips
    param([string]$LanguageTag, [string[]]$Tips)
    $lang = Get-WinUserLanguageList | Where-Object { $_.LanguageTag -eq $LanguageTag }
    return @{
        TipsOk = [bool]($lang -and ((@($lang.InputMethodTips) -join ';') -ieq ($Tips -join ';')))
        DefOk  = ((Get-WinDefaultInputMethodOverride -ErrorAction SilentlyContinue).InputMethodTip -eq $Tips[0])
    }
}

# $LanguageTag の入力方式を $Tips 単独にし (他の IME を外す)、既定入力方式を $Tips[0] に固定する。
# user scope。冪等。既定 override を張らないと言語リスト先頭 (通常 en-US) が既定になり、目的の
# 入力方式が既定にならない (別 IME を外すと古い override が失効して先頭へ落ちるため)。
# 反映にはサインアウトが要る。
function Set-InputMethod { # LanguageTag Tips
    param([string]$LanguageTag, [string[]]$Tips)
    if (-not $Tips -or $Tips.Count -eq 0) { return }
    $cur = Test-InputMethodCurrent $LanguageTag $Tips
    if ($cur.TipsOk -and $cur.DefOk) {
        Write-Ok "$LanguageTag の入力方式は設定済み (単独＋既定)"
    } else {
        if (-not $cur.TipsOk) {
            $list = Get-WinUserLanguageList
            $lang = $list | Where-Object { $_.LanguageTag -eq $LanguageTag }
            if (-not $lang) { Write-Warn "$LanguageTag が未追加のため入力方式を設定できません (設定→言語で追加)"; return }
            $lang.InputMethodTips.Clear()
            foreach ($t in $Tips) { [void]$lang.InputMethodTips.Add($t) }
            Set-WinUserLanguageList $list -Force
        }
        if (-not $cur.DefOk) { Set-WinDefaultInputMethodOverride -InputTip $Tips[0] }
        Write-Ok "$LanguageTag の入力方式を設定しました (単独＋既定。サインアウトで反映)"
    }
    # 設定だけ張っても、TIP の実体が登録されていなければ入力できない。「設定済み」で早期に
    # 返してしまうとこの状態を素通りするので、どちらの経路でも最後に見る。修復は消費側の
    # 担当 (TIP DLL の在り処が IME 実装ごとに違う) なので、ここは警告までに留める。
    $tipId = Get-InputMethodTipId $Tips[0]
    if ($tipId -and (Test-InputMethodTipMissing (Get-InputMethodTipState -Id $tipId))) {
        Write-Warn "$LanguageTag の TIP が登録されていません (設定は正しくても入力できません)"
        Write-Info 'IME を入れ直すか、TIP の DLL を regsvr32 で登録し直してください'
    }
}

# ============================================================
# TIP (TSF) 登録の実体
# ============================================================

# TIP 文字列 `<言語 ID 16進4桁>:{CLSID}{プロファイル GUID}` を分解する。形が違えば $null。
# LangKey は CTF\TIP\...\LanguageProfile の下のキー名 (言語 ID を 8 桁ゼロ埋めした
# 0x00000411 形式)。判定に要る情報はすべてこの 1 本の文字列から導けるので、消費側は
# 入力方式の設定 ($Tips) 以外に CLSID を二重管理しなくてよい。
function Get-InputMethodTipId { # Tip
    param([string]$Tip)
    if (-not $Tip) { return $null }
    $m = [regex]::Match($Tip, '^([0-9a-fA-F]{4}):(\{[0-9a-fA-F-]{36}\})(\{[0-9a-fA-F-]{36}\})$')
    if (-not $m.Success) { return $null }
    return @{
        LangKey = '0x' + $m.Groups[1].Value.ToLower().PadLeft(8, '0')
        Clsid   = $m.Groups[2].Value
        Profile = $m.Groups[3].Value
    }
}

# 登録を見るレジストリパス。CLSID は 64bit / 32bit で別ビュー (WOW6432Node) に入るので
# 両方を持つ。CTF\TIP はビュー共通。
function Get-InputMethodTipRegistryPath { # Id
    param([Parameter(Mandatory)][hashtable]$Id)
    return @{
        Server64 = "HKLM:\SOFTWARE\Classes\CLSID\$($Id.Clsid)\InProcServer32"
        Server32 = "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$($Id.Clsid)\InProcServer32"
        Profile  = "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$($Id.Clsid)\LanguageProfile\$($Id.LangKey)\$($Id.Profile)"
    }
}

# レジストリキーの既定値 ((default))。キーが無い・空なら $null。
function Get-InputMethodRegistryDefault { # Path
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $v = [string](Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue).'(default)'
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v
}

# 現在の登録状態を読むだけの関数 (良し悪しは決めない。判定は Get-InputMethodTipProblem)。
# $Dll64 / $Dll32 は「その版の TIP DLL が導入されているか」= 期待してよい登録の範囲で、
# DLL の在り処は IME 実装ごとに違うので消費側が渡す。片方しか無い機で誤検知しないための引数。
function Get-InputMethodTipState { # Id Dll64 Dll32
    param(
        [Parameter(Mandatory)][hashtable]$Id,
        [bool]$Dll64,
        [bool]$Dll32
    )
    $paths = Get-InputMethodTipRegistryPath -Id $Id
    $prof = $null
    if (Test-Path -LiteralPath $paths.Profile) {
        $prof = Get-ItemProperty -LiteralPath $paths.Profile -ErrorAction SilentlyContinue
    }
    return @{
        Dll64    = $Dll64
        Dll32    = $Dll32
        Server64 = (Get-InputMethodRegistryDefault -Path $paths.Server64)
        Server32 = (Get-InputMethodRegistryDefault -Path $paths.Server32)
        Profile  = [bool]$prof
        Enabled  = [bool]($prof -and $prof.PSObject.Properties['Enable'] -and [int]$prof.Enable -eq 1)
    }
}

# IME 本体が入っているか (TIP の DLL がひとつでも在るか)。入っていなければ登録が無いのは
# 当然なので、消費側は修復も診断の減点もしない。
function Test-InputMethodTipInstalled { # State
    param([hashtable]$State)
    return [bool]($State -and ($State.Dll64 -or $State.Dll32))
}

# 登録が「IME として使える」形かを見る。噛み合っていない理由の一覧を返す (空なら正常)。
# State だけで決まる純粋関数 (レジストリを読まない) ので、状態を組み立ててテストできる。
function Get-InputMethodTipProblem { # State
    param([hashtable]$State)
    if (-not $State) { return @('TIP の登録状態を読めない') }
    $problems = @()
    if ($State.Dll64 -and -not $State.Server64) {
        $problems += 'COM 登録が無い (64bit: Classes\CLSID\...\InProcServer32)'
    }
    if ($State.Dll32 -and -not $State.Server32) {
        $problems += 'COM 登録が無い (32bit: Classes\WOW6432Node\CLSID\...\InProcServer32)'
    }
    if (-not $State.Profile) {
        $problems += '言語プロファイルが無い (CTF\TIP\...\LanguageProfile)'
    } elseif (-not $State.Enabled) {
        $problems += '言語プロファイルが無効 (Enable=0)'
    }
    return $problems
}

# DLL の所在を知らなくても使える弱い判定。true = どのビューにも COM 登録が無い、あるいは
# 言語プロファイルが無い/無効で、ビット数に関係なく確実に使えない。Get-InputMethodTipProblem
# と違い「どの版が入っているか」を要求しないので、Set-InputMethod のように TIP 文字列しか
# 持たない経路から呼べる (代償として、片側のビューだけ消えた状態は拾えない)。
function Test-InputMethodTipMissing { # State
    param([hashtable]$State)
    if (-not $State) { return $true }
    if (-not ($State.Server64 -or $State.Server32)) { return $true }
    return (-not $State.Enabled)
}

# $Tip が使える形で登録されているか。$Dll64 / $Dll32 は Get-InputMethodTipState と同じ意味で、
# 省略時は「どちらのビューも要求しない」= Test-InputMethodTipMissing 相当の弱い判定になる。
# 消費側 doctor が「設定」(Test-InputMethodCurrent) とは独立に「登録の実体」を出すための入口。
function Test-InputMethodTipRegistered { # Tip Dll64 Dll32
    param(
        [Parameter(Mandatory)][string]$Tip,
        [bool]$Dll64,
        [bool]$Dll32
    )
    $id = Get-InputMethodTipId $Tip
    if (-not $id) { return $false }
    $state = Get-InputMethodTipState -Id $id -Dll64 $Dll64 -Dll32 $Dll32
    if (-not ($Dll64 -or $Dll32)) { return (-not (Test-InputMethodTipMissing $state)) }
    return (@(Get-InputMethodTipProblem -State $state).Count -eq 0)
}
