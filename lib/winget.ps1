#Requires -Version 5.1
#
# lib/winget.ps1: 汎用機構 — winget 呼び出しと PATH 操作、パッケージ導入ループ
#
# dotfiles-win.ps1 から dot-source される。どのパッケージを入れるか
# ($WingetPackages) は個人選択なので dotfiles-win.config.ps1。詳細は #6。

# winget をコンソール直書き (TTY) で呼び出すラッパー。終了コードを返す。
# winget はダウンロード進捗を CR (\r) で上書きする in-place スピナー
# として描画する。これを `& winget ... 2>&1 | ForEach-Object` のように
# PowerShell パイプライン経由で受けると、PowerShell が CR を行終端と
# みなしてしまい「スピナーの各コマが 1 行ずつ延々と改行で吐かれる」
# 状態になる。Start-Process -NoNewWindow なら winget が現在のコンソール
# ハンドルをそのまま継承するため、TTY 判定が通って in-place スピナー
# が正しく動く。代償として標準出力を捕捉できなくなる (パイプ経由に
# するとまた同じ問題が再発する) ため、出力のパターン解析は諦め、
# 終了コードと winget 自身のメッセージで判断する方針。
function Invoke-Winget {
    param([Parameter(Mandatory)][string[]]$WingetArgs)
    $proc = Start-Process -FilePath 'winget.exe' `
        -ArgumentList $WingetArgs `
        -Wait -NoNewWindow -PassThru
    return $proc.ExitCode
}

# User scope の PATH 環境変数に $Path を追加する。すでに含まれていれば
# false、追加した場合は true を返す。idempotent。
function Add-UserPathEntry {
    param([string]$Path)
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $userPath) { $userPath = '' }
    $entries = $userPath -split ';' | Where-Object { $_ }
    foreach ($e in $entries) {
        if ($e.TrimEnd('\').TrimEnd('/') -ieq $Path.TrimEnd('\').TrimEnd('/')) {
            return $false
        }
    }
    $newPath = if ($userPath) { "$userPath;$Path" } else { $Path }
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    # 現在のセッションにも反映
    $env:PATH = "$env:PATH;$Path"
    return $true
}

# 現在のプロセスの PATH をレジストリ (Machine + User) から再合成する。winget は導入した
# ツールのパスをレジストリの PATH には追加するが「実行中プロセスの PATH」は更新しないため、
# 同じ run の後半で直前に winget 導入したツール (node/go/rustup/uv 等) を呼ぼうとすると
# 見つからず失敗する。winget 導入フェーズ直後に本関数を呼べば、以降のステップから
# 導入済みツールが見えるようになる (新規環境を 1 回の setup で完走させるための要)。
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# $Id のパッケージが winget 上に導入済みか判定する (--id + -e で ID 厳密一致)。
# 出力は捨てて終了コードだけ見る (未導入なら NO_APPLICATIONS_FOUND で非 0)。
# 出力を捕捉しない Invoke-Winget と違い、ここは表示不要なので捨ててよいが、EAP Stop の
# まま native の stderr をリダイレクトすると PS5.1 で NativeCommandError になりうるため
# Invoke-Quiet で包む ($LASTEXITCODE はグローバルなので外で読める。詳細は lib/common.ps1)。
function Test-WingetInstalled {
    param([Parameter(Mandatory)][string]$Id)
    Invoke-Quiet { & winget.exe list --id $Id -e --disable-interactivity --accept-source-agreements *> $null }
    return ($LASTEXITCODE -eq 0)
}

# winget パッケージ群を導入/更新する。同 ID が winget 上に導入済みなら upgrade、
# 無ければ install。$Packages は @{ Id=...; Cmd=... } の配列 (個人選択。config 側で定義)。
# 導入判定にコマンドの存在 (Test-Cmd) は使わない — 別経路で入った同名コマンド
# (例: 手動導入の Python 3.9 が py を提供) を「導入済み」と誤判定すると、upgrade
# 対象の ID が実在しないため何も起きず、目的のパッケージが永遠に入らないため。
# winget の進捗 (CR ベースの in-place スピナー) を正しく表示させるため、
# Invoke-Winget は出力を捕捉せず winget にコンソール所有権を渡している。
# その代償として、過去にあった "install technology" 差異 (例: pwsh 7.5→7.6)
# の自動検知は行わない。出力は肉眼で見えるので、winget 自身が出す
# メッセージ (「This package cannot be upgraded ...」「アンインストールしてから
# 再インストール ...」等) を読んで判断する。
# winget が winget ソースと相関できる導入済みパッケージ ID の一覧を返す。
# `winget list` のカラム出力は Name の全角文字で桁がずれ Substring パースが壊れるため、
# 機械可読な `winget export` (JSON) を使う。msstore ソース (Store 管理で自動更新) は
# 監査対象外なので `-s winget` でソースごと除外する (相関計算も省ける)。失敗時は空配列。
function Get-WingetInstalledIds {
    $tmp = Join-Path $env:TEMP ('winget-export-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        # export は「ソースに無いパッケージ」の警告を大量に出すので出力は捨てる
        # (Invoke-Quiet: EAP Stop のまま stderr をリダイレクトすると PS5.1 で落ちるため)。
        Invoke-Quiet { & winget.exe export -o $tmp -s winget --disable-interactivity --accept-source-agreements 2>&1 | Out-Null }
        if (-not (Test-Path $tmp)) { return @() }
        $json = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        $ids = @()
        foreach ($src in @($json.Sources)) {
            foreach ($pkg in @($src.Packages)) {
                if ($pkg.PackageIdentifier) { $ids += [string]$pkg.PackageIdentifier }
            }
        }
        return $ids
    } catch {
        return @()
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# 追跡外 winget パッケージの監査 (Linux booch_doctor_apt_untracked の Windows 版)。
# $Tracked = 管理下の ID、$Ignore = 監査対象外の ID パターン (-like)。「入れているのに
# dotfiles 管理外」のものを可視化する。情報表示のみで missing 集計には影響しない。
function Show-WingetUntracked {
    param(
        [Parameter(Mandatory)][array]$Tracked,
        [array]$Ignore = @()
    )
    $installed = Get-WingetInstalledIds
    if (-not $installed) {
        Write-Status 'winget audit' 'SKIP' Yellow 'winget export から一覧を取得できません'
        return
    }
    $untracked = @($installed | Sort-Object -Unique | Where-Object {
        $id = $_
        if ($Tracked -contains $id) { return $false }
        foreach ($pat in $Ignore) { if ($id -like $pat) { return $false } }
        return $true
    })
    if ($untracked.Count -eq 0) {
        Write-Ok 'winget: 追跡外パッケージなし'
        return
    }
    Write-Warn ('winget: 管理外のパッケージが {0} 件あります (管理するなら $WingetPackages、恒久除外は $WingetAuditIgnore へ):' -f $untracked.Count)
    foreach ($id in $untracked) { Write-Host "      $id" }
}

function Install-WingetPackages {
    param([Parameter(Mandatory)][array]$Packages)
    foreach ($pkg in $Packages) {
        if (Test-WingetInstalled $pkg.Id) {
            Write-Ok ('{0} ({1}): already installed' -f $pkg.Id, $pkg.Cmd)
            Write-Info 'Checking for updates...'
            # install 側と同様に --id + -e で ID 厳密一致にする (部分一致での誤対象を防ぐ)。
            [void](Invoke-Winget @('upgrade', '--id', $pkg.Id, '-e', '--silent', '--disable-interactivity',
                '--accept-source-agreements', '--accept-package-agreements'))
        } else {
            Write-Info ('Installing {0}...' -f $pkg.Id)
            $ec = Invoke-Winget @('install', '--id', $pkg.Id, '-e', '--silent', '--disable-interactivity',
                '--accept-source-agreements', '--accept-package-agreements')
            if ($ec -ne 0) {
                if (-not $Script:IsElevated) {
                    Write-Fail ('Failed to install {0} (exit {1}) — 管理者権限が必要かもしれません' -f $pkg.Id, $ec)
                } else {
                    Write-Fail ('Failed to install {0} (exit {1})' -f $pkg.Id, $ec)
                }
            }
        }
    }
}
