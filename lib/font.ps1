#Requires -Version 5.1
#
# lib/font.ps1: 汎用機構 — per-user フォントの導入とセッション登録
#
# dotfiles-win.ps1 から dot-source される。どのフォントを入れるか ($Font:
# Family / Repo / AssetPattern / TtfPattern) は個人選択なので
# dotfiles-win.config.ps1。

# per-user フォントの HKCU 登録先 (3 関数で共用)。
$Script:FontRegPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

# 「どのリリースから入れたか」を控えるファイルのパス。
#
# フォント側にはこの情報が残らない (ttf 内部のバージョンは配布元のリリースタグと一致せず、
# ファイル名も版を含まない) ため、別に記録しないと更新の要否を判断できない。記録が無いと
# 「入っているかどうか」しか見られず、初回導入時の版のまま永久に古びる。
function Get-FontVersionStampPath {
    param([Parameter(Mandatory)][string]$Family)
    $slug = ($Family -replace '[^\w.-]', '-')
    return (Join-Path $env:LOCALAPPDATA ("Microsoft\Windows\Fonts\.booch-win-{0}.version" -f $slug))
}

# 配置するファイル名。リリースタグを埋めて元ファイルとは別名にする (上書きを避けるため)。
# タグが不明なときは元の名前のまま。ファイル名に使えない文字はタグから落とす。
function Get-FontDestFileName {
    param(
        [Parameter(Mandatory)][string]$SourceName,   # 例: PlemolJPConsoleNF-Regular.ttf
        [string]$Version                             # 例: v3.0.0
    )
    if (-not $Version) { return $SourceName }
    $slug = $Version -replace '[^\w.-]', '-'
    $base = [System.IO.Path]::GetFileNameWithoutExtension($SourceName)
    $ext = [System.IO.Path]::GetExtension($SourceName)
    return ('{0}_{1}{2}' -f $base, $slug, $ext)
}

# 記録されている導入済みバージョン (記録が無ければ '')。
function Get-FontInstalledVersion {
    param([Parameter(Mandatory)][string]$Family)
    $p = Get-FontVersionStampPath -Family $Family
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    $v = (Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue) -as [string]
    if (-not $v) { return '' }
    return $v.Trim()
}

# 指定フォントファミリが HKCU に登録済みか。
# $Family は表示名 (正規表現ではない) なので Escape してリテラル一致させる。
function Test-FontInstalled {
    param([Parameter(Mandatory)][string]$Family)
    if (-not (Test-Path $Script:FontRegPath)) { return $false }
    $props = Get-ItemProperty -Path $Script:FontRegPath -ErrorAction SilentlyContinue
    if (-not $props) { return $false }
    $pat = [regex]::Escape($Family)
    return [bool]($props.PSObject.Properties | Where-Object {
        $_.Name -match $pat
    })
}

# %LOCALAPPDATA%\...\Fonts へのコピー + HKCU レジストリ登録だけでは、
# 現在のセッションではフォントテーブルにロードされず、次回ログインまで
# 各アプリ (Windows Terminal / Chromium 系) から見えないケースがある。
# AddFontResource で GDI に即時登録し、WM_FONTCHANGE をブロードキャスト
# して動作中のアプリにフォント一覧の再取得を促す。レジストリ登録自体は
# 別途行われているので、ここでの登録は当該セッション限定で良い (次回
# ログイン時は Windows が HKCU から自動ロードする)。
function Register-FontInSession {
    param([Parameter(Mandatory)][string]$Family)
    if (-not (Test-Path $Script:FontRegPath)) { return 0 }
    $props = Get-ItemProperty -Path $Script:FontRegPath -ErrorAction SilentlyContinue
    if (-not $props) { return 0 }

    $pat = [regex]::Escape($Family)
    $entries = $props.PSObject.Properties | Where-Object {
        $_.Name -match $pat -and $_.Value
    }
    if (-not $entries) { return 0 }

    if (-not ('Dotfiles.FontApi' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Dotfiles {
    public static class FontApi {
        [DllImport("gdi32.dll", EntryPoint="AddFontResourceW", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern int AddFontResource(string lpszFilename);

        [DllImport("user32.dll", CharSet=CharSet.Auto, SetLastError=true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
            uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    }
}
"@
    }

    $count = 0
    foreach ($entry in $entries) {
        $path = [string]$entry.Value
        if (-not (Test-Path $path)) {
            # レジストリ値が相対パスだった場合のフォールバック
            $candidate = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts\$path"
            if (Test-Path $candidate) { $path = $candidate } else { continue }
        }
        if ([Dotfiles.FontApi]::AddFontResource($path) -gt 0) {
            $count++
        }
    }

    if ($count -gt 0) {
        # HWND_BROADCAST=0xFFFF, WM_FONTCHANGE=0x001D, SMTO_ABORTIFHUNG=0x0002
        $result = [IntPtr]::Zero
        [void][Dotfiles.FontApi]::SendMessageTimeout(
            [IntPtr]::new(0xFFFF),
            [uint32]0x001D,
            [IntPtr]::Zero, [IntPtr]::Zero,
            [uint32]0x0002,
            [uint32]1000,
            [ref]$result
        )
    }
    return $count
}

# GitHub releases の最新からフォント zip を取得し、per-user 配置 + HKCU 登録する。
# 導入済みでも呼べる (同名 ttf を上書きするので更新経路として使える)。成功したら
# 取得元のリリースタグを記録する (Get-FontInstalledVersion で読める)。
#   $Repo         : owner/name (例 yuru7/PlemolJP)
#   $AssetPattern : releases asset 名にマッチする正規表現 (zip を 1 つ選ぶ)
#   $TtfPattern   : zip 内 ttf の BaseName にマッチする正規表現 (入れる字形を絞る)
#   $Family       : HKCU 表示名のファミリ (例 "PlemolJP Console NF")
# Per-user フォントインストール (Windows 10 1809+ / Windows 11)。管理者不要。
# 戻り値: 導入したフォントファイル数。
function Install-Font {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$AssetPattern,
        [Parameter(Mandatory)][string]$TtfPattern,
        [Parameter(Mandatory)][string]$Family
    )
    $userFontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $fontRegPath = $Script:FontRegPath
    New-Item -ItemType Directory -Force -Path $userFontDir | Out-Null
    if (-not (Test-Path $fontRegPath)) {
        New-Item -Path $fontRegPath -Force | Out-Null
    }

    $tmpDir = Join-Path $env:TEMP ("font-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $progPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    try {
        $release = Get-GitHubLatestRelease -Repo $Repo
        if (-not $release) {
            throw "$Family の GitHub releases ($Repo) を取得できませんでした"
        }
        $asset = $release.assets |
            Where-Object { $_.name -match $AssetPattern } |
            Select-Object -First 1
        if (-not $asset) {
            throw "$Family の zip asset が GitHub releases ($Repo) に見つかりません"
        }

        $zipPath = Join-Path $tmpDir $asset.name
        Invoke-Download `
            -Uri $asset.browser_download_url `
            -OutFile $zipPath `
            -TimeoutSec (Get-EffectiveTimeout $Script:JobTimeoutSec)
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force

        $fonts = Get-ChildItem -Path $tmpDir -Recurse -Filter '*.ttf' |
            Where-Object { $_.BaseName -match $TtfPattern }

        if (-not $fonts) {
            throw "$TtfPattern にマッチする ttf がアーカイブから見つかりません"
        }

        # 配置名にリリースタグを埋めて「別ファイル」として置く。
        #
        # 同名で上書きしようとすると、動作中のアプリ (setup を走らせているターミナル自身を
        # 含む) が ttf を掴んでいて必ず失敗する。実測で 16/16 ファイルが使用中だった。
        # 別名なら書き込みは衝突せず、HKCU の表示名キーは同じまま値だけ新しいパスへ差し替わる
        # ので、フォント一覧に重複も出ない。旧ファイルはこの後の掃除で消す (掴まれていれば
        # 次回に回る)。
        $locked = @()
        $installedPaths = @()
        foreach ($font in $fonts) {
            $destName = Get-FontDestFileName -SourceName $font.Name -Version ([string]$release.tag_name)
            $destPath = Join-Path $userFontDir $destName
            try {
                Copy-Item $font.FullName -Destination $destPath -Force -ErrorAction Stop
                $installedPaths += $destPath
            } catch {
                # 同じ版を入れ直す場合など、配置先が既にあって掴まれているときはここへ来る。
                # 置けたものは残し、置けなかったものを名指しで報告する (復旧しやすさ優先)。
                $locked += $destName
                continue
            }

            # ファイル名から表示名を組み立てる
            #   <Family>-Regular → "<Family> (TrueType)"
            #   <Family>-Bold    → "<Family> Bold (TrueType)"
            $parts = ($font.BaseName -split '-', 2)
            $style = if ($parts.Length -gt 1) { $parts[1] } else { '' }
            if ($style -eq 'Regular') { $style = '' }
            $regName = if ($style) {
                "$Family $style (TrueType)"
            } else {
                "$Family (TrueType)"
            }
            Set-ItemProperty -Path $fontRegPath -Name $regName -Value $destPath -Type String
        }

        if ($locked.Count -gt 0) {
            throw ("{0} 個のフォントファイルを置けませんでした (使用中): {1}。フォントを使っているアプリ (ターミナル / エディタ) を閉じるか、サインアウトしてから再実行してください" -f
                $locked.Count, ($locked -join ', '))
        }

        # 旧版・旧命名 (バージョンを埋める前の名前) のファイルを掃除する。レジストリは
        # 新しいパスを指しているので実体は宙に浮いており、放置すると版ごとに数十 MB 積む。
        # 掴まれていれば消せないが、それは次回に回してよい (害は容量だけ)。
        # 対象は $TtfPattern に一致するファイル = このファミリのために置いたものだけ。
        foreach ($old in @(Get-ChildItem -LiteralPath $userFontDir -Filter '*.ttf' -File -ErrorAction SilentlyContinue)) {
            if ($old.BaseName -notmatch $TtfPattern) { continue }
            if ($installedPaths -contains $old.FullName) { continue }
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
        # 版の記録は全ファイルを置けたときだけ。失敗を記録すると、次回「最新」と誤判定して
        # 中途半端な状態のまま固定されてしまう。
        if ($release.tag_name) {
            Set-Content -LiteralPath (Get-FontVersionStampPath -Family $Family) `
                -Value ([string]$release.tag_name) -Encoding UTF8
        }
        return $fonts.Count
    } finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        $ProgressPreference = $progPref
    }
}
