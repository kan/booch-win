#Requires -Version 5.1
#
# lib/doctor.ps1: 汎用機構 — doctor のツール一覧チェックフレーム
#
# dotfiles-win.ps1 から dot-source される。どのツールを見るか
# ($DoctorTools) は個人選択なので dotfiles-win.config.ps1。詳細は #6。

# バージョン文字列から数値部分 (1.2 / 1.2.3 / 1.2.3.4) を取り出す。取れなければ ''。
# --version の出力は「gh version 2.96.0 (2026-07-02)」「v0.23.0」のように装飾がまちまちで、
# そのまま突き合わせると常に不一致になるため、比較用に数値だけへ寄せる。
function Get-VersionNumber {
    param([string]$Text)
    if (-not $Text) { return '' }
    if ($Text -match '(\d+(?:\.\d+)+)') { return $Matches[1] }
    return ''
}

# 現在版と最新版から、行末に添える注記を作る (不要なら '')。
#   最新を取れない   → (latest: unknown)     取得失敗を「最新」と見分けるため
#   現在版を取れない → (latest: X)           比較はできないが情報は落とさない
#   不一致           → (update available: X)
function Get-VersionNote {
    param([string]$Current, [string]$Latest)
    $cur = Get-VersionNumber $Current
    $lat = Get-VersionNumber $Latest
    if (-not $lat) { return '  (latest: unknown)' }
    if (-not $cur) { return "  (latest: $lat)" }
    if ($cur -ne $lat) { return "  (update available: $lat)" }
    return ''
}

# ツール一覧 (@{ Label; Cmd; Ver; Latest }) を順に判定し Write-Status で表示する。
# Ver は導入済みのときバージョン文字列を出すための scriptblock。1 つでも
# 未導入なら $true を返す (呼び出し側の missing 集計に使う)。
# $After は Label→scriptblock のマップ。該当ラベル行の直後にその scriptblock を
# 実行し、子行 (claude 直下のプラグイン列挙など) をネスト表示するのに使う。
#
# Latest (任意) は最新版を返す scriptblock。渡すと現在版と比較して上記の注記を添える。
# 遅れていても MISSING にはしない (動きはするので、可視化だけが目的)。どのツールを
# どこと比較するかは個人選択なので Latest の中身は消費側の config が持つ (Linux で
# booch_doctor_tool が機構、prefetch の URL が dotfiles 側なのと同じ分担)。
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
            $note = ''
            if ($t.Latest) {
                # 取得失敗で doctor 全体を落とさない (最新が不明なだけ)。
                $latest = ''
                try { $latest = (& $t.Latest) -as [string] } catch {}
                $note = Get-VersionNote -Current $v -Latest $latest
            }
            Write-Status $t.Label 'OK' Green "$v$note"
        } else {
            Write-Status $t.Label 'MISSING' Red
            $missing = $true
        }
        if ($After -and $After.ContainsKey($t.Label)) { & $After[$t.Label] }
    }
    return $missing
}
