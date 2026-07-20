#Requires -Version 5.1
#
# lib/sync.ps1: 汎用機構 — 設定ファイルの双方向同期エンジンと Transform
#
# dotfiles-win.ps1 から dot-source される。何を同期するか ($SyncPairs) は
# 個人選択なので dotfiles-win.config.ps1。ここは「やり方」だけ。詳細は #6。

function Test-FilesEqual {
    param([string]$A, [string]$B)
    if ((Get-Item $A).Length -ne (Get-Item $B).Length) { return $false }
    return (Get-FileHash $A).Hash -eq (Get-FileHash $B).Hash
}

# ディレクトリ配下 (再帰) のファイル一式が一致するか。ファイルの相対パス集合と、各ファイルの
# 内容の両方を見る。実体コピーで配る対象 (Copy-Item -Recurse で配備したスキル等) が配布元から
# ずれていないかを診断するための判定で、片方が無ければ $false。
#
# 「配るのに、配った結果がずれていないかは見ない」状態を作らないために要る — コピー方式は
# 配布元が更新されても配備先が黙って古いまま残るので、それを検出できるのは内容比較だけ。
function Test-DirectoryInSync {
    param(
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)][string]$DstDir
    )
    if (-not (Test-Path -LiteralPath $SrcDir) -or -not (Test-Path -LiteralPath $DstDir)) { return $false }
    $relOf = {
        param($root, $file)
        $file.FullName.Substring((Resolve-Path -LiteralPath $root).Path.Length).TrimStart('\')
    }
    $srcRel = @(Get-ChildItem -LiteralPath $SrcDir -Recurse -File | ForEach-Object { & $relOf $SrcDir $_ } | Sort-Object)
    $dstRel = @(Get-ChildItem -LiteralPath $DstDir -Recurse -File | ForEach-Object { & $relOf $DstDir $_ } | Sort-Object)
    # 大文字小文字は Windows のファイルシステムに合わせて無視する。
    if (($srcRel -join '|') -ne ($dstRel -join '|')) { return $false }
    foreach ($r in $srcRel) {
        if (-not (Test-FilesEqual (Join-Path $SrcDir $r) (Join-Path $DstDir $r))) { return $false }
    }
    return $true
}

# $SrcDir 直下のファイルを $DstDir へ一方向で配置する (内容が違うものだけコピー)。$SyncPairs の
# 双方向同期と違い「repo 側が正本」の配布用 (公開鍵・同梱データなど)。配置先が無ければ作る。
# コピーしたファイル名の配列を返す (表示や件数は呼び出し側が決める)。$SrcDir が無ければ空配列。
function Copy-FilesIfChanged { # SrcDir DstDir [Filter]
    param(
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)][string]$DstDir,
        [string]$Filter = '*'
    )
    if (-not (Test-Path $SrcDir)) { return @() }
    if (-not (Test-Path $DstDir)) { New-Item -ItemType Directory -Force $DstDir | Out-Null }
    $copied = @()
    foreach ($f in Get-ChildItem -Path $SrcDir -Filter $Filter -File) {
        $dst = Join-Path $DstDir $f.Name
        if (-not (Test-Path $dst) -or -not (Test-FilesEqual $f.FullName $dst)) {
            Copy-Item $f.FullName $dst -Force
            $copied += $f.Name
        }
    }
    return @($copied)
}

# ------------------------------------------------------------
# SyncPairs の表示ラベル
# doctor の config files 表示と setup 末尾の Invoke-Sync が同じ見た目に
# なるよう、ラベル導出をここに一元化する。repo 相対パスから共通ノイズの
# `claude/skills/` 接頭辞を落とす (例: japanese-tech-writing/SKILL.md)。
# ------------------------------------------------------------
function Get-SyncPairLabel {
    param([Parameter(Mandatory)]$Pair)
    return ($Pair.Repo -replace '^claude/skills/', '')
}

# ラベル列幅 = 最長ラベル + 余白 2 字。同期ペアの増減に自動追従し、
# はみ出しも過剰な余白も出さない (Write-Status の -LabelWidth に渡す)。
function Get-SyncPairLabelWidth {
    param([Parameter(Mandatory)][array]$Pairs)
    return (($Pairs | ForEach-Object { (Get-SyncPairLabel $_).Length } |
            Measure-Object -Maximum).Maximum) + 2
}

# ------------------------------------------------------------
# テキストファイル I/O（UTF-8 / BOM なし / 改行は読み書きで保持）
# repo の dotfiles は LF・BOM なし UTF-8 で統一しているため、それを
# 崩さずに内容を読み書きするための薄いラッパー。
# ------------------------------------------------------------
function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)  # BOM なし
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# ------------------------------------------------------------
# 機械固有値の展開 / 正規化（SyncPairs の Transform 用）
#
# リポジトリ側 (gitconfig-win) は機械非依存のベア名 op-ssh-sign.exe を
# 正本として持つ。一方 1Password デスクトップアプリは gpg.ssh.program を
# 自分が配置した絶対パスにしたがり、そうでないと「gitconfig を修正
# しますか」という通知を出し続ける。そこで:
#   - 展開 (repo → 環境): program 行をこの PC の絶対パスへ書き換える
#   - 正規化 (環境 → repo): 絶対パスをベア名へ戻す（repo に機械固有の
#     ユーザ名やパスを混入させない）
# 同期の一致判定も「環境ファイル == 展開後の repo」で行うため、絶対パス
# 状態を「最新」と認識でき、毎回 DIVERGED と誤判定しない。
# ------------------------------------------------------------

# 1Password (op-ssh-sign.exe) のこの PC での絶対パス。1Password CLI が
# %LOCALAPPDATA%\Microsoft\WindowsApps\ に固定名で配置するもので、
# 1Password アプリが「理想的」とみなすパスでもある。
function Get-OpSshSignPath {
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\op-ssh-sign.exe'
    if (Test-Path $p) { return $p }
    $cmd = Get-Command 'op-ssh-sign.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $p
}

# gitconfig 内の [gpg "ssh"] program 行の値を差し替える。インデント
# (タブ) は保持。op-ssh-sign を含む program 行のみが対象。
function Set-GitGpgProgram {
    param([Parameter(Mandatory)][string]$Content, [Parameter(Mandatory)][string]$Value)
    # 行末は [ \t]*$ に限定する。\s*$ だと \s が改行も含むため、置換が
    # program 行末の改行まで飲み込んで後続行と連結してしまう。
    $pattern = '(?m)^([ \t]*program[ \t]*=[ \t]*).*op-ssh-sign\.exe[ \t]*$'
    return [regex]::Replace($Content, $pattern, {
        param($m) $m.Groups[1].Value + $Value
    })
}

# repo の内容をこの PC 用に展開する（ベア名 → 絶対パス）。
function Expand-RepoToDeploy {
    param([Parameter(Mandatory)][string]$Transform, [Parameter(Mandatory)][string]$Content)
    switch ($Transform) {
        'GitGpgProgram' {
            $abs = (Get-OpSshSignPath) -replace '\\', '\\'  # git config 用に \ をエスケープ
            return Set-GitGpgProgram $Content $abs
        }
        default { return $Content }
    }
}

# 環境の内容を repo 用に正規化する（絶対パス → ベア名）。
function Normalize-DeployToRepo {
    param([Parameter(Mandatory)][string]$Transform, [Parameter(Mandatory)][string]$Content)
    switch ($Transform) {
        'GitGpgProgram' { return Set-GitGpgProgram $Content 'op-ssh-sign.exe' }
        default { return $Content }
    }
}

# repo と環境が同期済みか判定する。Transform 付きペアは「環境 == 展開後
# の repo」で比較し、機械固有展開を差分とみなさない。
function Test-PairInSync {
    param([Parameter(Mandatory)]$Pair, [Parameter(Mandatory)][string]$RepoFile, [Parameter(Mandatory)][string]$DestFile)
    if (-not $Pair.Transform) {
        return (Test-FilesEqual $RepoFile $DestFile)
    }
    $expected = Expand-RepoToDeploy $Pair.Transform (Read-TextFile $RepoFile)
    return ($expected -ceq (Read-TextFile $DestFile))
}

# repo → 環境へ配置する（Transform 付きなら展開してから書き込む）。
function Deploy-Pair {
    param([Parameter(Mandatory)]$Pair, [Parameter(Mandatory)][string]$RepoFile, [Parameter(Mandatory)][string]$DestFile)
    if ($Pair.Transform) {
        Write-TextFile $DestFile (Expand-RepoToDeploy $Pair.Transform (Read-TextFile $RepoFile))
    } else {
        Copy-Item $RepoFile $DestFile -Force
    }
}

# 環境 → repo へ取り込む（Transform 付きなら正規化してから書き込む）。
function Import-Pair {
    param([Parameter(Mandatory)]$Pair, [Parameter(Mandatory)][string]$RepoFile, [Parameter(Mandatory)][string]$DestFile)
    if ($Pair.Transform) {
        Write-TextFile $RepoFile (Normalize-DeployToRepo $Pair.Transform (Read-TextFile $DestFile))
    } else {
        Copy-Item $DestFile $RepoFile -Force
    }
}

# ------------------------------------------------------------
# 同期オーケストレーション
# 各 SyncPair を順に判定し、差分があれば diff を見せて対話選択 (r/e/s) で
# 反映する。何を同期するか ($Pairs) と repo の場所 ($DotfilesDir) は消費側が
# 渡し、判定・展開・書き込みは上のエンジン関数に委ねる。表示・対話の挙動は
# 従来 dotfiles-win.ps1 の Invoke-Sync と同一。
# ------------------------------------------------------------
function Invoke-BoochWinSync {
    param(
        [Parameter(Mandatory)][array]$Pairs,
        [Parameter(Mandatory)][string]$DotfilesDir
    )
    Write-Host '=== Config file sync ==='
    Write-Host ''

    foreach ($pair in $Pairs) {
        $repoFile = Join-Path $DotfilesDir $pair.Repo
        $destFile = $pair.Dest
        # 表示ラベルは doctor の config files と共通 (接頭辞除去)。
        $label = Get-SyncPairLabel $pair

        if (-not (Test-Path $repoFile)) {
            Write-Fail "${label}: repo file not found"
            continue
        }

        $destDir = Split-Path -Parent $destFile
        if ($destDir -and -not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }

        if (-not (Test-Path $destFile)) {
            Deploy-Pair $pair $repoFile $destFile
            Write-Ok "${label}: deployed (new)"
            continue
        }

        if (Test-PairInSync $pair $repoFile $destFile) {
            Write-Ok "${label}: up to date"
            continue
        }

        Write-Host ''
        Write-Warn "${label}: files differ"
        Write-Host '  --- diff (repo → environment) ---'
        try {
            # Windows PowerShell 5.1 は Get-Content の既定エンコーディングが OS の
            # コードページ (cp932 等) になり UTF-8 が化けるため UTF8 を明示する。
            # Transform 付きペアは「展開後の repo」と環境を比較し、機械固有展開を
            # 差分として見せない（本当に差している行だけを出す）。
            if ($pair.Transform) {
                $a = (Expand-RepoToDeploy $pair.Transform (Read-TextFile $repoFile)) -split "`n"
                $b = (Read-TextFile $destFile) -split "`n"
            } else {
                $a = Get-Content $repoFile -Encoding UTF8
                $b = Get-Content $destFile -Encoding UTF8
            }
            $diff = Compare-Object $a $b
            foreach ($line in $diff) {
                $marker = if ($line.SideIndicator -eq '<=') { '<' } else { '>' }
                Write-Host "  $marker $($line.InputObject)"
            }
        } catch {
            Write-Host '  (diff 表示に失敗)'
        }
        Write-Host ''
        Write-Host '  [r] Use repo version → deploy to environment'
        Write-Host '  [e] Use environment version → import to repo'
        Write-Host '  [s] Skip'
        $choice = Read-Host '  Choice [r/e/s]'

        switch ($choice.ToLower()) {
            'r' {
                Deploy-Pair $pair $repoFile $destFile
                Write-Ok "${label}: deployed from repo"
            }
            'e' {
                Import-Pair $pair $repoFile $destFile
                Write-Ok "${label}: imported to repo"
            }
            default {
                Write-Info "${label}: skipped"
            }
        }
    }
}
