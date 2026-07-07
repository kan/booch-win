#Requires -Version 5.1
#
# lib/doctor.ps1: 汎用機構 — doctor のツール一覧チェックフレーム
#
# dotfiles-win.ps1 から dot-source される。どのツールを見るか
# ($DoctorTools) は個人選択なので dotfiles-win.config.ps1。詳細は #6。

# ツール一覧 (@{ Label; Cmd; Ver }) を順に判定し Write-Status で表示する。
# Ver は導入済みのときバージョン文字列を出すための scriptblock。1 つでも
# 未導入なら $true を返す (呼び出し側の missing 集計に使う)。
# $After は Label→scriptblock のマップ。該当ラベル行の直後にその scriptblock を
# 実行し、子行 (claude 直下のプラグイン列挙など) をネスト表示するのに使う。
function Show-ToolList {
    param(
        [Parameter(Mandatory)][array]$Tools,
        [hashtable]$After
    )
    $missing = $false
    foreach ($t in $Tools) {
        if (Test-Cmd $t.Cmd) {
            $v = ''
            try {
                $raw = Invoke-Quiet { & $t.Ver 2>$null }
                $v = (@($raw) | Where-Object { $_ } | Select-Object -First 1) -as [string]
            } catch {}
            if (-not $v) { $v = 'installed' }
            Write-Status $t.Label 'OK' Green $v
        } else {
            Write-Status $t.Label 'MISSING' Red
            $missing = $true
        }
        if ($After -and $After.ContainsKey($t.Label)) { & $After[$t.Label] }
    }
    return $missing
}
