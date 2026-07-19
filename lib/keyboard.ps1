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
    if ($cur.TipsOk -and $cur.DefOk) { Write-Ok "$LanguageTag の入力方式は設定済み (単独＋既定)"; return }
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
