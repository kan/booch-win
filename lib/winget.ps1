#Requires -Version 5.1
#
# lib/winget.ps1: 汎用機構 — winget 呼び出し / PATH 操作 / パッケージ導入 / 設定の更新
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
#   ExitCode = $null            : 起動そのものに失敗した (winget.exe が無い等)、
#                                 または終了コードを取得できなかった
# どちらも「判定できなかった」であり、呼び出し側は成否のどちらかへ丸めずに扱うこと。
#
# $FilePath は通常 'winget.exe' のまま。差し替えを許すのは、終了コードを取れるかどうかが
# Start-Process の使い方に依存する (下の .Handle 参照) ので、winget を前提にせず実プロセスで
# 回帰を突けるようにするため。
#
# 出力はコンソールへ出さず一時ファイルへ捨てる。表示が要らない読み取り専用の経路
# なので、Invoke-Winget のようにコンソール所有権を渡す必要が無い (むしろ渡すと
# 中断できなくなる)。install / upgrade はここを通さない — インストーラーの実行中に
# kill するとパッケージが中途半端に残り、上限で得られるものより失うものが大きい。
function Invoke-WingetRead {
    param(
        [Parameter(Mandatory)][string[]]$WingetArgs,
        [int]$TimeoutSec = 0,
        [string]$FilePath = 'winget.exe'
    )
    $stem   = Join-Path $env:TEMP ('winget-read-' + [Guid]::NewGuid().ToString('N'))
    $outLog = "$stem.out.log"
    $errLog = "$stem.err.log"
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $WingetArgs `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    } catch {
        Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
        return @{ TimedOut = $false; ExitCode = $null }
    }
    # PS5.1 の Start-Process -PassThru は、リダイレクトを併用すると返す Process が
    # プロセスハンドルを保持しない。ハンドルが無いまま子が終了すると .ExitCode は $null に
    # なり、[int] へキャストすれば 0 — つまり「成功」に化ける。Get-WingetInstallState は
    # それを exit 0 = 導入済みと読むので、未導入のパッケージまで 'Installed' と判定され、
    # install ではなく upgrade が走って NO_APPLICATIONS_FOUND で毎回失敗する。
    # 起動直後に .Handle を評価してハンドルを開いておけば、終了後も .ExitCode を読める。
    # 取れなくても致命ではない (下で $null のまま返り 'Unknown' 扱いになる) ので握る。
    try { $null = $proc.Handle } catch { Write-Verbose "Handle の取得に失敗: $_" }
    try {
        if ($TimeoutSec -gt 0 -and -not $proc.WaitForExit($TimeoutSec * 1000)) {
            # 待っている間に自力で終わっていることがある (Kill は既に終了したプロセスで
            # 例外になる) ので、失敗は握って先へ進む。
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $null = $proc.WaitForExit(5000)
            return @{ TimedOut = $true; ExitCode = $null }
        }
        # 引数無しの WaitForExit は「子プロセスの終了」に加えて非同期の出力
        # ストリームの終端まで待つ。時間指定版の後にもう一度呼ぶことで、出力を取り
        # こぼさずに終了を確定させる。
        $proc.WaitForExit()
        # ここで $null なら「終了コードを取得できなかった」。[int] へ丸めると 0 = 成功に
        # なってしまうので、$null のまま返して呼び出し側の判定不能経路へ渡す。
        $code = $null
        try { $code = $proc.ExitCode } catch { Write-Verbose "ExitCode の取得に失敗: $_" }
        if ($null -eq $code) { return @{ TimedOut = $false; ExitCode = $null } }
        return @{ TimedOut = $false; ExitCode = [int]$code }
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

# winget の設定ファイル (settings.json) のパスを返す。winget は MSIX 版 (App Installer)
# と非パッケージ版で置き場が違うので、実在するディレクトリのほうを優先し、どちらも
# 無ければ MSIX 版の既定を返す ($env:LOCALAPPDATA が無ければ '')。
function Get-WingetSettingsPath {
    if (-not $env:LOCALAPPDATA) { return '' }
    $dirs = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Settings')
    )
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath $d) { return (Join-Path $d 'settings.json') }
    }
    return (Join-Path $dirs[0] 'settings.json')
}

# settings.json のテキストへ $Settings のキーだけを再帰的にマージし、
# @{ Changed = [bool]; Json = [string] } を返す (Linux booch の TOML キー単位更新と同じ
# 「他キーを壊さない」方針の JSON 版)。$Settings の値がハッシュテーブルならそのキーだけ
# 下位へ降りて設定し、それ以外 (スカラー・配列) は丸ごと置き換える。
#
# Changed はマージ前後を同じ整形で直列化して比べた結果なので、インデント等の整形差だけ
# では真にならない (無用な書き戻しを防ぐ)。JSON として読めないテキストは
# ConvertFrom-Json の例外をそのまま投げる — 握って空オブジェクトから作り直すと、手で
# 書いたコメント付き (winget が許す JSONC) の設定を丸ごと消してしまうため、呼び出し側に
# 「触らない」判断をさせる。
function Merge-WingetSettingsJson {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings
    )
    # JSON 由来の PSCustomObject を順序付きハッシュテーブルへ写す。[ordered] なのはキー順を
    # 保つため — PS5.1 の通常のハッシュテーブルは順序不定で、書き戻すたびに既存のキーが
    # 並び替わって差分がノイズになる。新しい入れ物へ写すので深いコピーにもなる (マージ前の
    # 状態を比較用に残せる)。
    function ToOrderedNode($node) {
        if ($node -is [System.Management.Automation.PSCustomObject]) {
            $h = [ordered]@{}
            foreach ($p in $node.PSObject.Properties) { $h[$p.Name] = ToOrderedNode $p.Value }
            return $h
        }
        if ($node -is [System.Collections.IDictionary]) {
            $h = [ordered]@{}
            foreach ($k in @($node.Keys)) { $h[[string]$k] = ToOrderedNode $node[$k] }
            return $h
        }
        if ($node -is [object[]]) { return @($node | ForEach-Object { ToOrderedNode $_ }) }
        return $node
    }
    # 双方がオブジェクトのときだけ下位へ降りる。片方がスカラーなら型が変わっているので
    # 置き換える (古い形の値を残すと winget が読めない設定になりうる)。
    function MergeIntoNode($target, $source) {
        foreach ($k in @($source.Keys)) {
            $key = [string]$k
            $val = $source[$k]
            if ($val -is [System.Collections.IDictionary] -and $target[$key] -is [System.Collections.IDictionary]) {
                MergeIntoNode $target[$key] $val
            } else {
                $target[$key] = ToOrderedNode $val
            }
        }
    }

    $before = [ordered]@{}
    $text = $Json.TrimStart([char]0xFEFF).Trim()
    if ($text) {
        # PS7 の ConvertFrom-Json はコメント付き (JSONC) を読めてしまい、パース → 再直列化で
        # コメントが落ちる。winget は settings.json のコメントを許すので、行頭コメントを
        # 見つけた時点で投げて呼び出し側に触らせない。PS5.1 はそもそもパースできず例外に
        # なるので、版によって「消える / 消えない」が分かれるのを防ぐ意味もある。
        # 行頭 (前が空白のみ) に限るのは、値の中の URL ("https://...") を誤検出しないため。
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '^\s*(//|/\*)') {
                throw 'コメント付き (JSONC) の設定は自動更新の対象外です'
            }
        }
        $parsed = ToOrderedNode (ConvertFrom-Json $text)
        if (-not ($parsed -is [System.Collections.IDictionary])) {
            throw 'JSON のトップレベルがオブジェクトではありません'
        }
        $before = $parsed
    }
    $after = ToOrderedNode $before
    MergeIntoNode $after $Settings

    # 比較は -Compress で整形を落としてから行う (書式の違いを変更と誤検知しない)。
    # -Depth は settings.json の入れ子には十分すぎる深さ。既定の 2 だと下位が
    # 文字列へ潰れて差分が消えるので必ず明示する。
    $depth = 32
    $sameJson = (ConvertTo-Json $before -Depth $depth -Compress) -eq
                (ConvertTo-Json $after  -Depth $depth -Compress)
    return @{ Changed = (-not $sameJson); Json = (ConvertTo-Json $after -Depth $depth) }
}

# winget の settings.json へ $Settings のキーだけを冪等に反映する。既存の他キー
# (ユーザーが winget settings で書いたもの) は保ち、変更が無ければ書かない。
# JSON として読めないときは警告して何もしない — 読めないものを上書きして失うほうが
# 大きいので、直すのは人の仕事にする。
function Update-WingetSettings {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [string]$Path = ''
    )
    if (-not $Path) { $Path = Get-WingetSettingsPath }
    if (-not $Path) {
        Write-Warn 'winget settings: 設定ファイルの場所を特定できません ($env:LOCALAPPDATA が空)'
        return
    }
    $json = ''
    # ReadAllText は BOM を判別して外す。Get-Content -Raw を使わないのは、PS5.1 の
    # 既定エンコーディングが UTF-8 でなく非 ASCII が化けるため。
    if (Test-Path -LiteralPath $Path) { $json = [IO.File]::ReadAllText($Path) }
    try {
        $r = Merge-WingetSettingsJson -Json $json -Settings $Settings
    } catch {
        Write-Warn ('winget settings: {0} を JSON として解釈できないため更新しません ({1})' -f $Path, $_.Exception.Message)
        return
    }
    if (-not $r.Changed) {
        Write-Ok 'winget settings: up to date'
        return
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    # BOM 無し UTF-8 で書く (設定パーサへ BOM を渡さない)。
    [IO.File]::WriteAllText($Path, $r.Json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ('winget settings: updated ({0})' -f $Path)
}
