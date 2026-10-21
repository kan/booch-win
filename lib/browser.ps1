#Requires -Version 5.1
#
# lib/browser.ps1: 汎用機構 — Chrome / Edge の更新の確認と導入、再起動待ちの判定
#
# dotfiles-win.ps1 から dot-source される。どのブラウザを対象にするかは消費側の config が決める。
#
# 更新には、設定画面の「更新を確認」と同じ COM の on-demand API (Update3WebMachine) を使う。
# 管理者権限は要らない。CLI の入口 (Chrome の `updater.exe --wake`、Edge の
# `MicrosoftEdgeUpdate.exe /ua`) は定期実行用で、前回の確認から一定時間 (Chrome は 4.5 時間) が
# 過ぎるまで確認しないので使わない。on-demand の確認は、定期実行の確認ではまだ届いていない版も
# 受け取る (段階的な配信のため。82 分前の定期確認で見つからなかった版が on-demand では見つかった)。
# winget も使わない。winget は Chrome の安定版を Beta の ID と取り違えることがあり、Edge は
# OS の部品という扱いで winget からは更新できない。
#
# ブラウザが起動中なら、新しい版は new_<exe> として置かれ、次の起動で切り替わる (設定画面で
# 「再起動」ボタンが出る状態と同じ)。作業中のタブを閉じることになるので、再起動は代わりにしない。
# 対象は全ユーザー向け (Program Files) の導入だけ。ユーザー単位の導入 (LOCALAPPDATA) は扱わない。
# 依存: Write-* / Write-Status (lib/common.ps1)、Get-EffectiveTimeout (lib/system.ps1)。
#
# テスト用の継ぎ目 (seam):
#   Get-BrowserInstalledVersion   導入済みの版 (レジストリの pv)
#   Get-BrowserExePath            実行ファイルのパス (App Paths)
#   Get-BrowserRunningVersion     実行ファイルの版 (起動中の版。再起動待ちなら pv より古い)
#   Invoke-BrowserOnDemandUpdate  COM の on-demand API で確認と導入を行う (ネットワーク、副作用)

# 対応するブラウザ。AppId は Omaha (Google Update / EdgeUpdate) のアプリ ID。
$Script:BrowserCatalog = @{
    Chrome = @{
        Label      = 'Chrome'
        ProgId     = 'GoogleUpdate.Update3WebMachine'
        AppId      = '{8A69D345-D564-463C-AFF1-A69D9E530F96}'
        ClientsKey = 'HKLM:\SOFTWARE\WOW6432Node\Google\Update\Clients'
        Exe        = 'chrome.exe'
    }
    Edge = @{
        Label      = 'Edge'
        ProgId     = 'MicrosoftEdgeUpdate.Update3WebMachine'
        AppId      = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
        ClientsKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients'
        Exe        = 'msedge.exe'
    }
}

# Omaha の CurrentState の値 (Update3Web の stateValue)。
$Script:BrowserStateUpdateAvailable = 4
$Script:BrowserStateInstallComplete = 14
$Script:BrowserStateNoUpdate        = 16
$Script:BrowserStateError           = 17
# 待ち続ける状態。確認中は 1-3 (初期化から確認まで)、導入中は 4-13 (ダウンロードから導入まで) と 15 (一時停止)。
$Script:BrowserStatesChecking   = @(1, 2, 3)
$Script:BrowserStatesInstalling = @(4..13) + 15
# 確認と導入それぞれの待ちの上限 (秒)。--no-timeout (Get-EffectiveTimeout が 0) なら無制限。
$Script:BrowserUpdateTimeoutSec = 600

# 対応するブラウザの名前 (Chrome / Edge) を返す。
function Get-BrowserName {
    return @($Script:BrowserCatalog.Keys | Sort-Object)
}

# $Name の定義を返す。対応していない名前なら throw する。
function Get-BrowserSpec {
    param([Parameter(Mandatory)][string]$Name)
    $spec = $Script:BrowserCatalog[$Name]
    if (-not $spec) { throw "対応していないブラウザです: $Name (対応: $((Get-BrowserName) -join ', '))" }
    return $spec
}

# 導入済みの版を返す (未導入なら '')。再起動待ちのときは、導入済みで切り替え待ちの新しい版になる。
function Get-BrowserInstalledVersion {
    param([Parameter(Mandatory)][string]$Name)
    $spec = Get-BrowserSpec $Name
    $key = Join-Path $spec.ClientsKey $spec.AppId
    $pv = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).pv
    if ($pv) { return [string]$pv }
    return ''
}

# 実行ファイルのパスを返す (見つからなければ '')。
function Get-BrowserExePath {
    param([Parameter(Mandatory)][string]$Name)
    $spec = Get-BrowserSpec $Name
    $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$($spec.Exe)"
    $path = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(default)'
    if ($path) { $path = ([string]$path).Trim('"') }
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    return ''
}

# 実行ファイルの版を返す (見つからなければ '')。起動中のブラウザはこの版で動いている。
function Get-BrowserRunningVersion {
    param([Parameter(Mandatory)][string]$Name)
    $exe = Get-BrowserExePath $Name
    if (-not $exe) { return '' }
    $ver = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if ($ver) { return [string]$ver }
    return ''
}

# 新しい版が導入済みで、ブラウザの再起動を待っているか (new_<exe> が置かれているか)。
function Test-BrowserRelaunchPending {
    param([Parameter(Mandatory)][string]$Name)
    $spec = Get-BrowserSpec $Name
    $exe = Get-BrowserExePath $Name
    if (-not $exe) { return $false }
    return (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $exe) "new_$($spec.Exe)"))
}

# COM の on-demand API で更新を確認し、新しい版があれば導入する。結果を返す (例外は投げない)。
#   State   'no-update' / 'updated' / 'error' / 'timeout'
#   Detail  error / timeout のときの説明
# 確認と導入はそれぞれ $TimeoutSec まで待つ (0 以下なら無制限)。待ちきれなければ取り消して timeout を返す。
function Invoke-BrowserOnDemandUpdate {
    param(
        [Parameter(Mandatory)][string]$ProgId,
        [Parameter(Mandatory)][string]$AppId,
        [int]$TimeoutSec = (Get-EffectiveTimeout $Script:BrowserUpdateTimeoutSec)
    )
    $updater = $null
    $bundle = $null
    try {
        $updater = New-Object -ComObject $ProgId
        $bundle = $updater.createAppBundleWeb()
        [void]$bundle.initialize()
        [void]$bundle.createInstalledApp($AppId)
        [void]$bundle.checkForUpdate()
        $busy = $Script:BrowserStatesChecking
        $state = Wait-BrowserBundleState -Bundle $bundle -Busy $busy -TimeoutSec $TimeoutSec
        $value = [int]$state.stateValue
        if ($value -eq $Script:BrowserStateNoUpdate) { return [pscustomobject]@{ State = 'no-update'; Detail = '' } }
        if ($value -eq $Script:BrowserStateUpdateAvailable) {
            [void]$bundle.install()
            $busy = $Script:BrowserStatesInstalling
            $state = Wait-BrowserBundleState -Bundle $bundle -Busy $busy -TimeoutSec $TimeoutSec
            $value = [int]$state.stateValue
            if ($value -eq $Script:BrowserStateInstallComplete) { return [pscustomobject]@{ State = 'updated'; Detail = '' } }
        }
        if ($value -eq $Script:BrowserStateError) {
            return [pscustomobject]@{ State = 'error'; Detail = ('error code 0x{0:X8}' -f ([int64]$state.errorCode -band 0xFFFFFFFFL)) }
        }
        if ($busy -notcontains $value) {
            # 待つ状態を抜けたのに、想定した終わり方 (更新なし / 導入完了 / エラー) のどれでもない
            return [pscustomobject]@{ State = 'error'; Detail = "想定外の状態で止まりました (state $value)" }
        }
        # 取り消せなくても結果 (timeout) は変わらないので、失敗は詳細ログにだけ残す
        try { [void]$bundle.cancel() } catch { Write-Verbose "cancel failed: $_" }
        return [pscustomobject]@{ State = 'timeout'; Detail = "$TimeoutSec 秒待っても終わりません (state $value)" }
    } catch {
        return [pscustomobject]@{ State = 'error'; Detail = "$_" }
    } finally {
        foreach ($o in @($bundle, $updater)) {
            if ($o -and [System.Runtime.InteropServices.Marshal]::IsComObject($o)) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o)
            }
        }
    }
}

# $Bundle の状態が $Busy の間 (最長 $TimeoutSec 秒。0 以下なら無制限) 待ち、最後の状態 (ICurrentState) を返す。
function Wait-BrowserBundleState {
    param(
        [Parameter(Mandatory)]$Bundle,
        [Parameter(Mandatory)][int[]]$Busy,
        [int]$TimeoutSec = 0
    )
    $deadline = if ($TimeoutSec -gt 0) { (Get-Date).AddSeconds($TimeoutSec) } else { [datetime]::MaxValue }
    while ($true) {
        $state = $Bundle.appWeb(0).currentState
        if ($Busy -notcontains [int]$state.stateValue -or (Get-Date) -ge $deadline) { return $state }
        Start-Sleep -Milliseconds 500
    }
}

# $Name のブラウザの更新を確認し、新しい版があれば導入して結果を表示する (例外は投げない)。
# 未導入なら何もしない。ブラウザが起動中で切り替えが次の起動になるときは、再起動を促す。
function Update-Browser {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = (Get-EffectiveTimeout $Script:BrowserUpdateTimeoutSec)
    )
    try {
        $spec = Get-BrowserSpec $Name
    } catch {
        Write-Fail "$_"
        return
    }
    $label = $spec.Label
    $before = Get-BrowserInstalledVersion $Name
    if (-not $before) {
        Write-Info "${label}: 未導入のため飛ばします"
        return
    }
    $result = Invoke-BrowserOnDemandUpdate -ProgId $spec.ProgId -AppId $spec.AppId -TimeoutSec $TimeoutSec
    $after = Get-BrowserInstalledVersion $Name
    switch ($result.State) {
        'error'   { Write-Fail "${label}: 更新の確認に失敗: $($result.Detail)"; return }
        'timeout' { Write-Warn "${label}: 更新が終わりません: $($result.Detail)"; return }
    }
    if (Test-BrowserRelaunchPending $Name) {
        Write-Warn "${label}: $(Get-BrowserPendingText -Name $Name -Installed $after -Fallback $before)。$label を再起動すると切り替わります"
    } elseif ($result.State -eq 'updated') {
        Write-Ok "${label}: $before → $after"
    } else {
        Write-Ok "${label}: $after (up to date)"
    }
}

# 再起動待ちの表示 ('<起動中の版> → <導入済みの版> は導入済みです')。起動中の版が取れなければ $Fallback を使う。
function Get-BrowserPendingText {
    param([Parameter(Mandatory)][string]$Name, [string]$Installed, [string]$Fallback)
    $running = Get-BrowserRunningVersion $Name
    $from = if ($running) { $running } else { $Fallback }
    return "$from → $Installed は導入済みです"
}

# doctor 向けに $Name の版と再起動待ちを 1 行で表示する (ネットワークへは出ない)。
# ラベルは小文字の名前 (chrome / edge)。未導入なら SKIP、再起動待ちなら WARN。
function Show-BrowserStatus {
    param([Parameter(Mandatory)][string]$Name)
    $label = (Get-BrowserSpec $Name).Label.ToLowerInvariant()
    $installed = Get-BrowserInstalledVersion $Name
    if (-not $installed) {
        Write-Status $label 'SKIP' DarkGray '未導入'
    } elseif (Test-BrowserRelaunchPending $Name) {
        Write-Status $label 'WARN' Yellow "$(Get-BrowserPendingText -Name $Name -Installed $installed)  (再起動で切り替わります)"
    } else {
        Write-Status $label 'OK' Green $installed
    }
}
