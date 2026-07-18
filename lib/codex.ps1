#Requires -Version 5.1
#
# lib/codex.ps1: 機構 — Codex CLI (GitHub Releases バイナリ) の導入
#
# dotfiles-win.ps1 から dot-source される。どの repo から入れるか ($CodexRepo)
# は config。GitHub 最新タグ取得は lib/github.ps1。

# Codex CLI バイナリを GitHub releases の最新から ~/.local/bin へ配置する。
function Install-Codex {
    param([Parameter(Mandatory)][string]$Repo)
    $archMap = @{
        'AMD64' = 'x86_64'
        'ARM64' = 'aarch64'
    }
    $arch = $archMap[$env:PROCESSOR_ARCHITECTURE]
    if (-not $arch) {
        throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE"
    }
    $binName = "codex-${arch}-pc-windows-msvc.exe"
    $destDir = Join-Path $HOME '.local\bin'
    $dest    = Join-Path $destDir 'codex.exe'
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    # 最終配置先へ直接ダウンロードすると、通信断・タイムアウト時に既存の正常な
    # codex.exe を部分書き込みで破損させ起動不能にしうる。一時ファイルへ落とし、
    # 成功後に Move-Item -Force で原子的に入れ替える (失敗時は旧バイナリを残す)。
    $tmp = "${dest}.download"
    try {
        Invoke-Download `
            -Uri "https://github.com/$Repo/releases/latest/download/${binName}" `
            -OutFile $tmp `
            -TimeoutSec (Get-EffectiveTimeout $Script:JobTimeoutSec)
        Move-Item -Force -Path $tmp -Destination $dest
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# codex の現在バージョンと、GitHub releases の最新タグを取得する。
# 両者が一致するなら 30MB の再ダウンロードをスキップできる。
function Get-CodexInstalledVersion {
    if (-not (Test-Cmd 'codex')) { return '' }
    try {
        $raw = Invoke-Quiet { & codex --version 2>$null | Select-Object -First 1 }
        if ($raw) {
            return (($raw -as [string]) -split '\s+' | Where-Object { $_ } | Select-Object -Last 1)
        }
    } catch {}
    return ''
}

function Get-CodexLatestVersion {
    param([Parameter(Mandatory)][string]$Repo)
    $tag = Get-GitHubLatestReleaseTag -Repo $Repo
    if ($tag) {
        return ($tag -replace '^rust-v', '' -replace '^v', '')
    }
    return ''
}

# TOML テキストの「トップレベル」キーを冪等に設定して返す (Linux booch_set_toml_key の
# Windows 版)。キーを最初のセクションヘッダ ([projects...] 等) より後に置くとその
# セクションのキーになってしまうため、置換・挿入ともに先頭〜最初のセクションの範囲に
# 限定する。$RawValue は TOML 表記そのまま (例: '"gpt-5.4"')。CRLF は LF へ正規化する
# (TOML として等価。混在改行を作らないため)。
# 複数行値 (配列等) の継続行は、クォート文字列とコメントを除いた括弧の増減で近似追跡し、
# セクションヘッダにもキー行にも見なさない — `notify = [` の次行が `[` で始まっても
# 配列の途中へキーを挿入して TOML を壊さないため (完全な TOML パーサではない。文字列中の
# エスケープ引用符のような極端なケースまでは追わない)。キー一致は -cmatch (TOML の
# キーは大文字小文字を区別するため。-match だと別キー 'Model' を書き換えてしまう)。
function Set-TomlTopLevelKey {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$RawValue
    )
    $body = ($Content -replace "`r`n", "`n").TrimEnd("`n")
    if ($body -eq '') { return "$Key = $RawValue`n" }
    $lines = $body -split "`n"

    # 行 i の開始時点の括弧深さ (0 = トップレベル文脈、>0 = 複数行値の継続中)。
    $depths = New-Object int[] $lines.Count
    $d = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $depths[$i] = $d
        $stripped = $lines[$i] -replace "'[^']*'", '' -replace '"(\\.|[^"\\])*"', ''
        $stripped = ($stripped -split '#', 2)[0]
        $d += ([regex]::Matches($stripped, '[\[{]')).Count - ([regex]::Matches($stripped, '[\]}]')).Count
        if ($d -lt 0) { $d = 0 }
    }

    $sectionIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($depths[$i] -eq 0 -and $lines[$i] -match '^\s*\[') { $sectionIdx = $i; break }
    }
    $limit = if ($sectionIdx -ge 0) { $sectionIdx } else { $lines.Count }

    $keyPat = '^[ \t]*' + [regex]::Escape($Key) + '[ \t]*='
    for ($i = 0; $i -lt $limit; $i++) {
        if ($depths[$i] -eq 0 -and $lines[$i] -cmatch $keyPat) {
            $lines[$i] = "$Key = $RawValue"
            return (($lines -join "`n") + "`n")
        }
    }

    # 未存在: トップレベル末尾 (= 最初のセクションの直前、セクションが無ければ末尾) に挿入。
    # 注意: if 式から返る 1 要素配列は unwrap されて文字列になり、+ が文字列連結に化けて
    # 改行が消えるため、加算の左辺を @() で確実に配列へ戻す。
    $newLine = "$Key = $RawValue"
    if ($sectionIdx -ge 0) {
        $head = if ($sectionIdx -gt 0) { $lines[0..($sectionIdx - 1)] } else { @() }
        $tail = $lines[$sectionIdx..($lines.Count - 1)]
        $lines = @($head) + @($newLine) + @($tail)
    } else {
        $lines = @($lines) + @($newLine)
    }
    return (($lines -join "`n") + "`n")
}

# TOML ファイルのトップレベル `key = value` だけを順序付きで読み取る。
# コメント行・空行を飛ばし、最初のセクションヘッダ (`[section]`) に達したら打ち切る。
# 値は TOML 表記のまま保持するため、そのまま Set-TomlTopLevelKey / Update-CodexConfig
# の入力へ再利用できる。用途は dotfiles 側の codex/config.toml を SSOT として読むなど。
function Get-TomlTopLevelKeys {
    param([Parameter(Mandatory)][string]$Path)
    $keys = [ordered]@{}
    if (-not (Test-Path $Path)) { return $keys }

    $content = Read-TextFile $Path
    $lines = ($content -replace "`r`n", "`n") -split "`n"
    foreach ($line in $lines) {
        if ($line -match '^\s*\[') { break }
        if ($line -match '^\s*($|#)') { continue }
        if ($line -cmatch '^[ \t]*([A-Za-z0-9_.-]+)[ \t]*=[ \t]*(.*)$') {
            $keys[$Matches[1]] = $Matches[2]
        }
    }
    return $keys
}
# ~/.codex/config.toml をキー単位で冪等更新する (Linux booch_finalize_codex_config と
# 対称)。ユーザーが足した他キー・[projects] 等のセクションは壊さない。$Keys は
# [ordered]@{ キー = TOML 表記の値 } (選択は config の $CodexConfigKeys)。
# 依存: Read-TextFile / Write-TextFile (lib/sync.ps1)。entry が全 lib をまとめて
# dot-source するため実行時は常に解決される。
function Update-CodexConfig {
    param([Parameter(Mandatory)]$Keys)
    $configDir  = Join-Path $HOME '.codex'
    $configFile = Join-Path $configDir 'config.toml'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    $content = if (Test-Path $configFile) { Read-TextFile $configFile } else { '' }
    $new = $content
    foreach ($k in $Keys.Keys) {
        $new = Set-TomlTopLevelKey -Content $new -Key $k -RawValue $Keys[$k]
    }
    if ($new -cne $content) {
        Write-TextFile $configFile $new
        Write-Ok "codex config.toml: キーを更新 ($($Keys.Keys -join ', '))"
    } else {
        Write-Ok 'codex config.toml: up to date'
    }
}
