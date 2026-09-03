#Requires -Version 5.1
#
# lib/doctor.ps1: 汎用機構 — doctor のツール一覧チェックフレーム
#
# dotfiles-win.ps1 から dot-source される。どのツールを見るか
# ($DoctorTools) は個人選択なので dotfiles-win.config.ps1。詳細は #6。
# ディスクの空き (Show-DiskFree) と WSL の ext4.vhdx サイズ (Show-WslVhdxSize) もここに置く。
# 後者は lib/system.ps1 の Get-WslVhdxPath / Get-FileAllocatedSize を使う
# (エントリが両方 dot-source する前提)。

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

# ツール 1 つが導入済みかを判定する。PATH (Test-Cmd) で見つかるか、winget の導入済み
# ID 集合 $WingetIds に WingetId が厳密一致すれば導入済み。どちらかで足りるのは、
# 「PATH に実行ファイルを出さない」もの (MSVC の link.exe は開発者シェルの中にしか出ない)
# と「winget 以外の経路・別変種の ID で入っている」ものの両方を拾うため。
# $WingetIds が空 (未取得・取得失敗) なら PATH だけで見る。PATH にも出ないツールは
# 「未導入」ではなく判定できなかっただけなので、Show-ToolList 側でその場合を分けて出す
# (ここは真偽値しか返さないため、区別は呼び出し側が持つ)。ID 集合の取得は呼び出し側の
# 仕事 (Get-WingetInstalledIds を 1 回呼んで doctor 内で使い回す。ツールごとに winget を
# 叩くと読み取り上限×個数かかる)。
function Test-ToolInstalled {
    param(
        [Parameter(Mandatory)]$Tool,
        [array]$WingetIds = @()
    )
    if ($Tool.Cmd -and (Test-Cmd $Tool.Cmd)) { return $true }
    # 空・未取得の集合では -contains が素直に $false を返す (＝PATH の判定だけが残る)。
    if ($Tool.WingetId) { return ($WingetIds -contains [string]$Tool.WingetId) }
    return $false
}

# ツール一覧 (@{ Label; Cmd; Ver; Latest; WingetId; Optional }) を順に判定し
# Write-Status で表示する。
# Ver は導入済みのときバージョン文字列を出すための scriptblock。1 つでも
# 未導入なら $true を返す (呼び出し側の missing 集計に使う)。
# $After は Label→scriptblock のマップ。該当ラベル行の直後にその scriptblock を
# 実行し、子行 (claude 直下のプラグイン列挙など) をネスト表示するのに使う。
#
# Latest (任意) は最新版を返す scriptblock。渡すと現在版と比較して上記の注記を添える。
# 遅れていても MISSING にはしない (動きはするので、可視化だけが目的)。どのツールを
# どこと比較するかは個人選択なので Latest の中身は消費側の config が持つ (Linux で
# booch_doctor_tool が機構、prefetch の URL が dotfiles 側なのと同じ分担)。
#
# WingetId (任意) は導入判定に使う winget のパッケージ ID。$WingetIds に
# Get-WingetInstalledIds の結果を渡すと、PATH に出ないツールも導入済みと判定できる。
# $WingetIds が空 (取得できなかった) なら、その行は MISSING ではなく判定不能の SKIP にする。
# Optional (任意) は「入っていなくてもよい」宣言 (Install-WingetPackages の同名キーと対)。
# 未導入なら MISSING ではなく SKIP 行にし、missing 集計にも数えない。未導入のときは
# Latest も引かない (ネットワークを使うものがあるうえ、比較する現在版が無い)。
function Show-ToolList {
    param(
        [Parameter(Mandatory)][array]$Tools,
        [hashtable]$After,
        [array]$WingetIds = @()
    )
    $missing = $false
    foreach ($t in $Tools) {
        if (Test-ToolInstalled -Tool $t -WingetIds $WingetIds) {
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
        } elseif ($t.WingetId -and @($WingetIds).Count -eq 0) {
            # ID 集合を取れなかった回 (winget の応答待ちが上限を超過した等)。WingetId を
            # 添えるのは PATH に出ないツールなので、PATH で見つからなくても未導入とは限らない。
            # MISSING にすると winget が詰まった回だけ doctor が exit 1 になるため、判定でき
            # なかったことを出す (Get-WingetInstallState の 'Unknown' を丸めないのと同じ扱い)。
            Write-Status $t.Label 'SKIP' DarkGray '判定不能 (winget の一覧を取得できません)'
        } elseif ($t.Optional) {
            # 未導入が正常な状態なので赤くしない。ただし黙って消すと「宣言したのに出ない」
            # と読めるので、任意ゆえの skip だと分かる行を残す。
            Write-Status $t.Label 'SKIP' DarkGray '未導入 (任意)'
        } else {
            Write-Status $t.Label 'MISSING' Red
            $missing = $true
        }
        if ($After -and $After.ContainsKey($t.Label)) { & $After[$t.Label] }
    }
    return $missing
}

# ドライブの空き容量を 1 行で出す。$WarnGB 未満なら WARN (＋任意の案内 $Hint)。
# ディスク逼迫は「ツールが最新か」とは別軸だが、放置すると導入・ビルドが静かに失敗するので
# 診断に載せる。閾値 0 は判定なし (表示だけ)。取得できないドライブは SKIP。
# WSL を使う環境では実消費の大半が ext4.vhdx なので、消費側は Show-WslVhdxSize と併せて出す。
# Linux 側 booch の booch_doctor_disk と対称。
function Show-DiskFree {
    param(
        [string]$Drive = 'C',
        [int]$WarnGB = 0,
        [string]$Hint = ''
    )
    $label = "disk ${Drive}:"
    $d = Get-PSDrive -Name $Drive -PSProvider FileSystem -ErrorAction SilentlyContinue
    if (-not $d -or $null -eq $d.Free) {
        Write-Status $label 'SKIP' DarkGray "空き容量を取得できません"
        return $false
    }
    $freeGB = [math]::Round($d.Free / 1GB, 1)
    $totalGB = [math]::Round(($d.Used + $d.Free) / 1GB, 1)
    $detail = '空き {0} GB / {1} GB' -f $freeGB, $totalGB
    if ($WarnGB -gt 0 -and $d.Free -lt ($WarnGB * 1GB)) {
        Write-Status $label 'WARN' Yellow ('{0} ← {1} GB 未満' -f $detail, $WarnGB)
        if ($Hint) { Write-Host "      $Hint" }
        return $true
    }
    Write-Status $label 'OK' Green $detail
    return $false
}

# WSL ディストロの ext4.vhdx のサイズを列挙する (情報表示のみ)。
# sparse な vhdx は論理サイズが減らないので、ドライブの空きに効く「実占有」を主に出し、
# 論理サイズは括弧で添える (実測で 151GB / 論理 213GB のように 60GB 以上ずれる)。
function Show-WslVhdxSize {
    $vhdxs = Get-WslVhdxPath
    if (-not $vhdxs) {
        Write-Status 'wsl ext4.vhdx' 'SKIP' DarkGray 'WSL ディストロが見つかりません'
        return
    }
    foreach ($v in $vhdxs) {
        $logical   = [math]::Round((Get-Item $v.Vhdx).Length / 1GB, 1)
        $allocated = [math]::Round((Get-FileAllocatedSize $v.Vhdx) / 1GB, 1)
        Write-Status ('  {0} vhdx' -f $v.Name) 'OK' Green ('実占有 {0} GB (論理 {1} GB)' -f $allocated, $logical)
    }
}
