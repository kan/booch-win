#Requires -Version 5.1
#
# lib/font.ps1: 汎用機構 — per-user フォントの導入とセッション登録
#
# dotfiles-win.ps1 から dot-source される。どのフォントを入れるか ($Font:
# Family / Repo / AssetPattern / TtfPattern) は個人選択なので
# dotfiles-win.config.ps1。詳細は kan/dotfiles#6。

# per-user フォントの HKCU 登録先 (3 関数で共用)。
$Script:FontRegPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

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

        foreach ($font in $fonts) {
            $destPath = Join-Path $userFontDir $font.Name
            Copy-Item $font.FullName -Destination $destPath -Force

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

        return $fonts.Count
    } finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        $ProgressPreference = $progPref
    }
}
