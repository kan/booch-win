#Requires -Version 5.1
#
# lib/codex.ps1: 機構 — Codex CLI (公式インストーラー) の導入と config.toml の更新
#
# dotfiles-win.ps1 から dot-source される。最新版の確認に使う repo ($CodexRepo) は
# config。GitHub 最新タグ取得は lib/github.ps1。
#
# 導入は公式インストーラー (install.ps1) に任せる。Codex CLI は codex.exe 単体では
# 動かず、同じリリースの付随物 (codex-code-mode-host.exe / rg.exe /
# codex-command-runner.exe / codex-windows-sandbox-setup.exe) を決まった配置で要する。
# インストーラーはそれらをパッケージごと %CODEX_HOME%\packages\standalone へ展開し
# (SHA256 検証つき)、見える bin dir (既定 %LOCALAPPDATA%\Programs\OpenAI\Codex\bin) を
# junction で張り、User PATH に足す。
# 依存: Invoke-Download / Get-EffectiveTimeout (lib/download.ps1)、Update-SessionPath
# (lib/winget.ps1)、Get-VersionNumber (lib/doctor.ps1)。entry が全 lib をまとめて dot-source する。
#
# テスト用の継ぎ目 (seam):
#   Save-CodexInstaller      install.ps1 の取得 (ネットワーク)
#   Invoke-CodexInstaller    install.ps1 を子プロセスで実行し終了コードを返す
#   Get-CodexVersionOutput   指定した codex.exe の --version 出力

# GitHub のタグ (rust-vX.Y.Z / vX.Y.Z) を、codex --version とインストーラーの -Release が使う素の版にする。
function ConvertTo-CodexVersion {
    param([string]$Tag)
    return ($Tag -replace '^rust-v', '' -replace '^v', '')
}

# インストーラーが codex.exe を置く見える bin dir。install.ps1 と同じく
# CODEX_INSTALL_DIR を優先し、無ければ既定の場所を返す。
function Get-CodexBinDir {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_INSTALL_DIR)) {
        return $env:CODEX_INSTALL_DIR
    }
    return (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin')
}

# インストーラーがパッケージを置くディレクトリ (releases\ と current を持つ)。
function Get-CodexStandaloneDir {
    $codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $env:USERPROFILE '.codex' } else { $env:CODEX_HOME }
    return (Join-Path $codexHome 'packages\standalone')
}

# current (junction) が指す版ディレクトリの名前 (<版>-<target>)。current が無ければ空。
function Get-CodexCurrentReleaseName {
    $current = Join-Path (Get-CodexStandaloneDir) 'current'
    if (-not (Test-Path -LiteralPath $current)) { return '' }
    $target = @((Get-Item -LiteralPath $current -Force).Target) | Select-Object -First 1
    if (-not $target) { return '' }
    return (Split-Path -Leaf ([string]$target).TrimEnd('\', '/'))
}

# current と $Keep (直前の版の名前) 以外の版ディレクトリを削除する。インストーラーは古い版を
# 消さない (1 版あたり数百 MB)。直前の版を残すのは、更新前から動いている codex のセッションが
# 自分の版の付随ファイルを使い続けるため。比較は名前で行う (パスの表記揺れで current を消さない)。
# 作業中の .staging.* はインストーラー自身が掃除するので触らない。
# 使用中の版は残す。Remove-Item -Recurse は消せるファイルから消していき、実行中の exe で止まるので、
# そのまま消すと付随ファイルだけが消えた壊れた版が残る。そこで 2 段に分ける。(1) 古い版の
# ディレクトリ名を .booch-old.* に変える (実行中の exe を含むディレクトリは名前を変えられないので、
# 使用中の版はここで残る)。(2) .booch-old.* を消す (前回消しきれなかった分もここで消し直す)。
function Remove-CodexOldRelease {
    param([string]$Keep = '')
    $current = Get-CodexCurrentReleaseName
    if (-not $current) { return }
    $releases = Join-Path (Get-CodexStandaloneDir) 'releases'
    if (-not (Test-Path -LiteralPath $releases -PathType Container)) { return }
    $trashPrefix = '.booch-old.'
    $old = Get-ChildItem -LiteralPath $releases -Directory -Force |
        Where-Object { -not $_.Name.StartsWith('.') -and $_.Name -ne $current -and $_.Name -ne $Keep }
    foreach ($dir in $old) {
        try {
            Rename-Item -LiteralPath $dir.FullName -NewName ($trashPrefix + $dir.Name) -ErrorAction Stop
        } catch {
            Write-Warn "codex: 使用中のため古い版を残す ($($dir.FullName))"
        }
    }
    foreach ($dir in Get-ChildItem -LiteralPath $releases -Directory -Force -Filter "$trashPrefix*") {
        try {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warn "codex: 古い版を削除できない ($($dir.FullName)): $_"
        }
    }
}

# 以前の booch-win (単一バイナリ方式) が codex.exe を置いていた場所。
function Get-LegacyCodexPath {
    return (Join-Path $HOME '.local\bin\codex.exe')
}

function Save-CodexInstaller {
    param([Parameter(Mandatory)][string]$OutFile)
    Invoke-Download -Uri 'https://chatgpt.com/codex/install.ps1' -OutFile $OutFile `
        -TimeoutSec (Get-EffectiveTimeout $Script:JobTimeoutSec)
}

# install.ps1 を子プロセスで実行し、終了コードを返す。
# 子プロセスにするのは、install.ps1 が StrictMode / $ErrorActionPreference を書き換え、
# 失敗時に exit するため (dot-source や & で呼ぶと呼び出し側のセッションを巻き込む)。
# CODEX_NON_INTERACTIVE=1 で「今すぐ起動するか」等の確認を抑止する (無人実行で
# Read-Host に止まらないように)。環境変数は子へ継承させた後に元へ戻す。
function Invoke-CodexInstaller {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Release
    )
    # 今動いている PowerShell と同じ実行ファイルを使う。ISE などコンソール以外のホストは
    # -File を受け付けないので、そのときは Windows PowerShell で起動する。
    $shell = (Get-Process -Id $PID).Path
    if ([IO.Path]::GetFileNameWithoutExtension($shell) -notin @('pwsh', 'powershell')) {
        $shell = 'powershell.exe'
    }
    $prev = $env:CODEX_NON_INTERACTIVE
    $env:CODEX_NON_INTERACTIVE = '1'
    try {
        # 子の出力は画面へ流す。パイプラインに残すと戻り値 (終了コード) に混ざる。
        & $shell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Release $Release | Out-Host
        return $LASTEXITCODE
    } finally {
        $env:CODEX_NON_INTERACTIVE = $prev
    }
}

function Get-CodexVersionOutput {
    param([Parameter(Mandatory)][string]$Path)
    # scriptblock から参照するためローカルへ移す (param を直接使うと解析器が未使用と誤検出する)。
    $exe = $Path
    try {
        $raw = Invoke-Quiet { & $exe --version 2>$null | Select-Object -First 1 }
    } catch {
        # 起動できない (壊れたバイナリ等) ときは版が取れないものとして扱う。
        return ''
    }
    if ($raw) { return ($raw -as [string]) }
    return ''
}

# 以前の booch-win が置いた単一バイナリ (~\.local\bin\codex.exe) を削除する。
# 残すと PATH の順によってはこちらが先に当たり、動かない単体の codex が起動し続ける。
# 消すのは通常ファイルで、--version が codex-cli を名乗るものだけ (別物を巻き込まない)。
# 削除したら $true を返す。
function Remove-LegacyCodexBinary {
    param([string]$Path = (Get-LegacyCodexPath))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    $binExe = Join-Path (Get-CodexBinDir) 'codex.exe'
    if ($item.FullName.Equals([IO.Path]::GetFullPath($binExe), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if ((Get-CodexVersionOutput -Path $Path) -notmatch '^codex-cli\s') { return $false }
    Remove-Item -LiteralPath $Path -Force
    return $true
}

# 旧単一バイナリの削除を試み、結果を表示する。失敗 (実行中でロックされている等) は警告だけにする。
# Install-Codex もこれを呼ぶが、Install-Codex は版が最新と違うときにしか呼ばれないので、それだけでは
# 削除に一度失敗すると再試行されない。利用側は導入済みで Install-Codex を呼ばない回にこれを呼ぶ。
function Clear-LegacyCodexBinary {
    try {
        if (Remove-LegacyCodexBinary) {
            Write-Info "codex: 旧配置の単一バイナリを削除 ($(Get-LegacyCodexPath))"
        }
    } catch {
        Write-Warn "codex: 旧配置の単一バイナリを削除できない ($(Get-LegacyCodexPath)): $_"
    }
}

# Codex CLI を公式インストーラーで導入 / 更新する。$Version は x.y.z (rust-v / v 接頭辞可)
# か latest。インストーラーの latest は releases.openai.com で決まり、Get-CodexLatestVersion
# (GitHub) とずれることがあるので、版を比べてから入れる利用側はその版を渡す。
# 導入後は現セッションの PATH をレジストリから組み直し (インストーラーが User PATH に足した
# bin dir を、同じセッションの版の確認や doctor から見えるようにする)、直前の版より古い版と
# 旧単一バイナリを消す。
function Install-Codex {
    param([string]$Version = 'latest')
    $release = if ([string]::IsNullOrWhiteSpace($Version)) { 'latest' } else { ConvertTo-CodexVersion $Version }
    $previous = Get-CodexCurrentReleaseName
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-installer-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    try {
        $installer = Join-Path $tmpDir 'install.ps1'
        Save-CodexInstaller -OutFile $installer
        $code = Invoke-CodexInstaller -ScriptPath $installer -Release $release
        if ($code -ne 0) {
            throw "Codex installer failed (exit $code)"
        }
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Update-SessionPath
    Remove-CodexOldRelease -Keep $previous
    # 旧バイナリの削除は導入の成否に含めない (実行中でロックされていると消せないが、導入自体は済んでいる)。
    Clear-LegacyCodexBinary
}

# インストーラーが導入した codex の版 (未導入なら空)。PATH 上の codex ではなく見える
# bin dir の codex.exe を見る。旧単一バイナリだけが残っている環境を「未導入」と判定し、
# 再導入 (= 移行) を走らせるため。
function Get-CodexInstalledVersion {
    $exe = Join-Path (Get-CodexBinDir) 'codex.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return '' }
    return (Get-VersionNumber (Get-CodexVersionOutput -Path $exe))
}

function Get-CodexLatestVersion {
    param([Parameter(Mandatory)][string]$Repo)
    $tag = Get-GitHubLatestReleaseTag -Repo $Repo
    if ($tag) {
        return (ConvertTo-CodexVersion $tag)
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
