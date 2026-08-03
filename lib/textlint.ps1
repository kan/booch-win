#Requires -Version 5.1
#
# lib/textlint.ps1: 汎用機構 — textlint 一式のローカル install
#
# dotfiles-win.ps1 から dot-source される。何を入れるか・どこへ置くか
# ($Script:TextlintSrc / $Script:TextlintDest) は個人選択なので
# dotfiles-win.config.ps1。
#
# feature-review スキル等は ~/.config/textlint-mcp-server/node_modules/.bin/textlint を
# git bash 経由で直叩きする。Linux 版 setup/jobs.sh の job_textlint と同じ構成
# (package.json を実行用 dir へ同期 install + 個人設定 .textlintrc.json 配置) を作り、
# Windows でも同じパスで textlint が引けるようにする。node/npm は winget
# (OpenJS.NodeJS.LTS) で導入済み前提。

# $SrcDir (repo の textlint/) の package.json を $DestDir へ同期 install し、
# .textlintrc.json を配置する。booch_npm_local_install + job_textlint の Windows 版。
#
# $SrcDir が package-lock.json を持たないときは install に続けて update も走らせる
# (booch の booch_npm_local_install と同じ判断。Linux/Windows で版の追従を揃える)。
# $DestDir に残る lockfile は初回 install の副産物だが、npm install は**それが
# package.json のレンジを満たす限り古い版を保持する**ため、レンジ内に新版が出ても
# 再実行で永久に前進しない (textlint が ^15.7.1 のまま 15.8.0 へ上がらなかった実例)。
# src に lockfile が**ある**ときは意図された版固定とみなし install のみ。レンジ外
# (メジャー跨ぎ) は動かないので、package.json の手 bump が要る点は変わらない。
function Install-Textlint {
    param(
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)][string]$DestDir
    )
    if (-not (Test-Cmd 'npm')) {
        Write-Fail 'npm が見つからないため textlint をインストールできません'
        return
    }
    $pkg = Join-Path $SrcDir 'package.json'
    if (-not (Test-Path $pkg)) {
        Write-Warn "textlint: $pkg が無いためスキップ"
        return
    }

    Write-Info 'Installing/updating textlint...'
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    Copy-Item $pkg $DestDir -Force
    # src の lockfile は「意図された版固定」の signal。あるときは尊重して update しない。
    $lock = Join-Path $SrcDir 'package-lock.json'
    $pinned = Test-Path $lock
    if ($pinned) { Copy-Item $lock $DestDir -Force }

    # cwd を汚さず $DestDir で install する。npm は警告 / 進捗を stderr に書くため
    # Invoke-Quiet で無害化する (詳細は lib/common.ps1)。
    Push-Location $DestDir
    try {
        Invoke-Quiet { & npm install --no-audit --no-fund 2>&1 | Out-Null }
        if (-not $pinned) {
            # レンジ内最新へ追従させる (dest の lockfile が古い版を塞ぐのを解く)。
            Invoke-Quiet { & npm update --no-audit --no-fund 2>&1 | Out-Null }
        }
    } finally {
        Pop-Location
    }

    # 個人設定 .textlintrc.json を install 後に配置する (job_textlint と同じ順序)。
    # skill が --config で参照する設定ファイルなので、欠けると textlint が設定不在で
    # 落ちる。silent コピーだと欠落に気付けないため、配備の成否を明示報告する。
    $rc = Join-Path $SrcDir '.textlintrc.json'
    if (Test-Path $rc) {
        Copy-Item $rc $DestDir -Force
        Write-Ok "textlint: .textlintrc.json を配備 ($(Join-Path $DestDir '.textlintrc.json'))"
    } else {
        Write-Warn "textlint: $rc が無いため .textlintrc.json を配備できず"
    }

    $bin = Join-Path $DestDir 'node_modules\.bin\textlint.cmd'
    if (Test-Path $bin) {
        $ver = (@(Invoke-Quiet { & $bin --version 2>$null }) | Where-Object { $_ } | Select-Object -First 1)
        Write-Ok "textlint: installed/updated ($ver)"
    } else {
        Write-Fail 'textlint: install failed'
    }
}
