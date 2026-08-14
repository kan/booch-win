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

# 読み取り系 winget 呼び出しの既定タイムアウト (秒)。エントリ側が
# $Script:WingetReadTimeoutSec を定義していればそれを優先し、--no-timeout
# (Get-EffectiveTimeout が 0 を返す) なら従来どおり無制限になる。
# 既定を控えめ (60 秒) にしているのは、winget が起動のたびにソースインデックス
# (cdn.winget.microsoft.com) を参照しうるためで、そこが詰まると 1 パッケージあたり
# 無限に待つ。読み取り 1 回ぶんの上限であって、全体の予算ではない。
function Get-WingetReadTimeout {
    $sec = 60
    if ($null -ne $Script:WingetReadTimeoutSec) { $sec = [int]$Script:WingetReadTimeoutSec }
    return (Get-EffectiveTimeout $sec)
}

# 副作用の無い読み取り系 winget を、上限付きで実行する。戻り値は
# @{ TimedOut = [bool]; ExitCode = [int] または $null }。
#   TimedOut = $true            : 上限を超えたので winget を終了させた
#   ExitCode = $null            : 起動そのものに失敗した (winget.exe が無い等)
# どちらも「判定できなかった」であり、呼び出し側は成否のどちらかへ丸めずに扱うこと。
#
# 出力はコンソールへ出さず一時ファイルへ捨てる。表示が要らない読み取り専用の経路
# なので、Invoke-Winget のようにコンソール所有権を渡す必要が無い (むしろ渡すと
# 中断できなくなる)。install / upgrade はここを通さない — インストーラーの実行中に
# kill するとパッケージが中途半端に残り、上限で得られるものより失うものが大きい。
function Invoke-WingetRead {
    param(
        [Parameter(Mandatory)][string[]]$WingetArgs,
        [int]$TimeoutSec = 0
    )
    $stem   = Join-Path $env:TEMP ('winget-read-' + [Guid]::NewGuid().ToString('N'))
    $outLog = "$stem.out.log"
    $errLog = "$stem.err.log"
    try {
        $proc = Start-Process -FilePath 'winget.exe' -ArgumentList $WingetArgs `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    } catch {
        Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
        return @{ TimedOut = $false; ExitCode = $null }
    }
    try {
        if ($TimeoutSec -gt 0 -and -not $proc.WaitForExit($TimeoutSec * 1000)) {
            # 待っている間に自力で終わっていることがある (Kill は既に終了したプロセスで
            # 例外になる) ので、失敗は握って先へ進む。
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $null = $proc.WaitForExit(5000)
            return @{ TimedOut = $true; ExitCode = $null }
        }
        # 引数無しの WaitForExit は「子プロセスの終了」に加えて非同期の出力
        # ストリームの終端まで待つ。時間指定版の後にもう一度呼ぶことで ExitCode を
        # 確定させる (PS5.1 で ExitCode が $null になる事故を避ける)。
        $proc.WaitForExit()
        return @{ TimedOut = $false; ExitCode = [int]$proc.ExitCode }
    } finally {
        Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
    }
}

# $Id のパッケージが winget 上に導入済みかを 3 値で返す (--id + -e で ID 厳密一致)。
#   'Installed'    : 導入済み (exit 0)
#   'NotInstalled' : 未導入 (NO_APPLICATIONS_FOUND 等で非 0)
#   'Unknown'      : タイムアウト・起動失敗で判定できなかった
# 真偽値にしないのは、'Unknown' をどちらへ丸めても嬉しくないため。$false に倒せば
# install が、$true に倒せば upgrade が走り、どちらもソース参照で同じく止まりうる。
# 呼び出し側は 'Unknown' を skip して次回の実行に任せること (冪等なので実害は無い)。
function Get-WingetInstallState {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Nullable[int]]$TimeoutSec = $null
    )
    if ($null -eq $TimeoutSec) { $TimeoutSec = Get-WingetReadTimeout }
    $r = Invoke-WingetRead -TimeoutSec $TimeoutSec -WingetArgs @(
        'list', '--id', $Id, '-e', '--disable-interactivity', '--accept-source-agreements')
    if ($r.TimedOut -or $null -eq $r.ExitCode) { return 'Unknown' }
    if ($r.ExitCode -eq 0) { return 'Installed' }
    return 'NotInstalled'
}

# winget が winget ソースと相関できる導入済みパッケージ ID の一覧を返す。
# `winget list` のカラム出力は Name の全角文字で桁がずれ Substring パースが壊れるため、
# 機械可読な `winget export` (JSON) を使う。msstore ソース (Store 管理で自動更新) は
# 監査対象外なので `-s winget` でソースごと除外する (相関計算も省ける)。失敗時は空配列。
# タイムアウト・起動失敗も同じく空配列 — 呼び出し側は既に「取得できなかった」を
# 扱えるので、判定不能を別の状態として持ち込む必要が無い。
function Get-WingetInstalledIds {
    param([Nullable[int]]$TimeoutSec = $null)
    if ($null -eq $TimeoutSec) { $TimeoutSec = Get-WingetReadTimeout }
    $tmp = Join-Path $env:TEMP ('winget-export-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        # export は「ソースに無いパッケージ」の警告を大量に出すが、Invoke-WingetRead が
        # 出力ごと捨てるので気にしなくてよい。終了コードは見ない — 一部のパッケージを
        # 相関できないだけでも非 0 になりうるのに対し、出力された JSON は使えるため。
        $r = Invoke-WingetRead -TimeoutSec $TimeoutSec -WingetArgs @(
            'export', '-o', $tmp, '-s', 'winget', '--disable-interactivity', '--accept-source-agreements')
        if ($r.TimedOut -or $null -eq $r.ExitCode) { return @() }
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
        Write-Status 'winget audit' 'SKIP' Yellow 'winget export から一覧を取得できません (応答待ちの上限超過を含む)'
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

# upgrade の終了コードが「実行することが無かった (失敗ではない)」を意味するか。
#
# winget upgrade は対象が最新のときも非 0 を返す。それを一律に失敗として出すと毎回
# ノイズになるので、既知の「何もすることが無い」コードだけを成功扱いにし、それ以外は
# 呼び出し側が可視化できるようにする。
#   0          : 実際に更新した
#   0x8A15002B : APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (適用できる更新が無い)
#                実機確認: 最新の Git.Git への upgrade がこれを返す
# 対象 ID が winget ソースと相関できない等は別コード (0x8A150014 など) になるので、
# ここでは成功扱いにしない — 「追跡している ID が実は更新できない」を隠さないため。
function Test-WingetUpgradeNoop {
    param([Parameter(Mandatory)][int]$ExitCode)
    return ($ExitCode -eq 0 -or $ExitCode -eq -1978335189)
}

# winget パッケージ群を導入/更新する。同 ID が winget 上に導入済みなら upgrade、
# 無ければ install。$Packages は @{ Id=...; Cmd=... } の配列 (個人選択。config 側で定義)。
# 導入判定にコマンドの存在 (Test-Cmd) は使わない — 別経路で入った同名コマンド
# (例: 手動導入の Python 3.9 が py を提供) を「導入済み」と誤判定すると、upgrade
# 対象の ID が実在しないため何も起きず、目的のパッケージが永遠に入らないため。
# 判定できなかったパッケージ (Get-WingetInstallState が 'Unknown') は警告して飛ばす。
# winget の進捗 (CR ベースの in-place スピナー) を正しく表示させるため、
# Invoke-Winget は出力を捕捉せず winget にコンソール所有権を渡している。
# その代償として、過去にあった "install technology" 差異 (例: pwsh 7.5→7.6)
# の自動検知は行わない。出力は肉眼で見えるので、winget 自身が出す
# メッセージ (「This package cannot be upgraded ...」「アンインストールしてから
# 再インストール ...」等) を読んで判断する。
function Install-WingetPackages {
    param([Parameter(Mandatory)][array]$Packages)
    foreach ($pkg in $Packages) {
        $state = Get-WingetInstallState $pkg.Id
        if ($state -eq 'Unknown') {
            # 導入状態が分からないまま install / upgrade へ倒すと、どちらもソース参照で
            # 同じく止まりうる。1 回飛ばして次のパッケージへ進み、次回の実行に任せる。
            Write-Warn ('{0} ({1}): 導入状態を判定できませんでした (winget の応答待ちが上限を超過)。今回はスキップします' -f $pkg.Id, $pkg.Cmd)
            continue
        }
        if ($state -eq 'Installed') {
            Write-Ok ('{0} ({1}): already installed' -f $pkg.Id, $pkg.Cmd)
            Write-Info 'Checking for updates...'
            # install 側と同様に --id + -e で ID 厳密一致にする (部分一致での誤対象を防ぐ)。
            $ec = Invoke-Winget @('upgrade', '--id', $pkg.Id, '-e', '--silent', '--disable-interactivity',
                '--accept-source-agreements', '--accept-package-agreements')
            # 更新の失敗を握り潰すと、更新が何度失敗しても setup ログに何も出ない
            # (install の失敗は Write-Fail していたので非対称だった)。ツールは古いまま
            # でも動くので致命ではなく、警告として出す。
            if (-not (Test-WingetUpgradeNoop $ec)) {
                Write-Warn ('{0}: 更新に失敗しました (exit 0x{1:X8})。上の winget の出力を確認してください' -f $pkg.Id, $ec)
            }
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
