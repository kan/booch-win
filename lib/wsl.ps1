#Requires -Version 5.1
#
# lib/wsl.ps1: 汎用機構 — WSL2 とディストロの導入、WSL 本体の版の確認と更新
#
# dotfiles-win.ps1 から dot-source される。どのディストロを入れるかは個人選択なので消費側の
# config が持ち、ここは wsl.exe を叩く「やり方」だけを提供する。案内文言と y/N は状態を返して
# 消費側に任せる (次の手順は利用側の運用に依るため)。
# 依存: Test-IsElevated / Get-CurrentProcessAncestor (lib/system.ps1)、Get-GitHubLatestReleaseTag
# (lib/github.ps1)、Get-VersionNumber (lib/doctor.ps1)。entry が全 lib をまとめて dot-source する。
#
# 公開 API:
#   Get-WslDistros([-Running])     導入済み (-Running なら起動中) のディストロ名の配列
#   Install-WslDistro(Distro)      WSL2 + 指定ディストロを導入し、結果の状態文字列を返す
#   Get-WslUpdateStatus(Repo)      WSL 本体の導入済みの版と最新版を比べ、更新の要否を返す
#   Update-WslPackage(Latest)      wsl --update を実行し、結果の状態文字列を返す

# WSL ディストロ名の配列。-Running なら起動中のものだけ。wsl.exe は一覧を UTF-16 で出すため、
# コンソールの出力エンコーディング次第で 1 文字ごとに null が挟まる。null を除いてから行に分ける。
# wsl.exe が非 0 で終わったとき (該当するディストロが無いと案内文を出して失敗する) は空配列。
function Get-WslDistros {
    param([switch]$Running)
    # wsl.exe が無いと、2>&1 で混ぜたエラー文を名前として返し、$LASTEXITCODE も前のコマンドの値のままになる。
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    $listArgs = @('--list', '--quiet')
    if ($Running) { $listArgs += '--running' }
    $raw = Invoke-Quiet { & wsl.exe @listArgs 2>&1 | Out-String }
    if ($LASTEXITCODE -ne 0) { return @() }
    return @(($raw -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# WSL2 + $Distro を導入する (既定バージョン 2 + wsl --install -d ... --no-launch)。
# --no-launch にするのは初回起動のユーザー作成が対話のため (呼び出し側が案内する)。
# wsl --install は機能有効化に管理者権限が要る。初回は機能有効化だけ済んで WSL の再起動を
# 待つ状態になることがあり、その場合ディストロはまだ現れない。状態を返して呼び出し側が
# 案内を出し分ける:
#   'already'       既に導入済み (何もしない)
#   'needs-admin'   管理者権限が無いため実行できない
#   'installed'     ディストロ導入まで完了
#   'needs-restart' 機能は有効化したが WSL の再起動が要る (再実行で続きから)
function Install-WslDistro { # Distro
    param([string]$Distro)
    if ((Get-WslDistros) -contains $Distro) { return 'already' }
    if (-not (Test-IsElevated)) { return 'needs-admin' }
    # wsl.exe は正常時も stderr へ進捗を書くため、EAP を緩めて native の停止を避ける
    # (PS5.1 では Stop のまま native の stderr が NativeCommandError になる)。
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & wsl.exe --set-default-version 2 | Out-Null
        & wsl.exe --install -d $Distro --no-launch
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ((Get-WslDistros) -contains $Distro) { return 'installed' }
    return 'needs-restart'
}

# 導入済みの WSL 本体の版 (x.y.z)。未導入なら ''。wsl --version は UTF-16 で文言も翻訳されるので、
# Store パッケージの版から取る (4 要素を 3 要素にそろえ、GitHub のタグと比べられるようにする)。
function Get-WslPackageVersion {
    $pkg = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $pkg) { return '' }
    $v = [string]$pkg.Version -as [version]
    if (-not $v) { return '' }
    return '{0}.{1}.{2}' -f $v.Major, $v.Minor, $v.Build
}

# $Repo (例: microsoft/WSL) の GitHub の最新リリース (プレリリースを除く) の版。取れなければ ''。
function Get-WslLatestVersion {
    param([Parameter(Mandatory)][string]$Repo)
    return (Get-VersionNumber (Get-GitHubLatestReleaseTag -Repo $Repo))
}

# このプロセスが WSL から起動されているか (祖先に wsl.exe / wslhost.exe / wslrelay.exe があるか)。
# 祖先を 1 つも読めない (プロセス一覧を取れない) ときは真を返す。WSL を止める更新を見送る側に倒すため。
function Test-LaunchedFromWsl {
    $ancestors = @(Get-CurrentProcessAncestor)
    if ($ancestors.Count -eq 0) { return $true }
    foreach ($p in $ancestors) {
        if ($p.Name -match '^(wsl|wslhost|wslrelay)\.exe$') { return $true }
    }
    return $false
}

# WSL 本体の導入済みの版と $Repo の最新版を比べ、@{ State; Current; Latest; Running } を返す。
# Running は起動中のディストロ名の配列で、State が available のときだけ調べる (他は空)。
# 消費側は available のときに案内と y/N を出し、Update-WslPackage -Latest $s.Latest を呼ぶ。
#   'not-installed'    WSL 本体が入っていない
#   'unknown'          最新版を確認できない (GitHub に届かない等)
#   'up-to-date'       最新版以上
#   'skipped-from-wsl' 更新はあるが、WSL から起動されているので更新できない (呼び出し元ごと止まるため)
#   'available'        更新できる
# Store の自動更新と併用してもよい (最新なら up-to-date になるだけ)。
function Get-WslUpdateStatus {
    param([Parameter(Mandatory)][string]$Repo)
    $s = [pscustomobject]@{ State = ''; Current = (Get-WslPackageVersion); Latest = ''; Running = @() }
    if (-not $s.Current) { $s.State = 'not-installed'; return $s }
    $s.Latest = Get-WslLatestVersion -Repo $Repo
    $latest = $s.Latest -as [version]
    if (-not $latest) { $s.State = 'unknown'; return $s }
    if (([version]$s.Current) -ge $latest) { $s.State = 'up-to-date'; return $s }
    if (Test-LaunchedFromWsl) { $s.State = 'skipped-from-wsl'; return $s }
    $s.Running = @(Get-WslDistros -Running)
    $s.State = 'available'
    return $s
}

# `wsl --update` を実行し、結果の状態文字列を返す。更新は WSL の VM を止め、中で動いている作業は
# すべて止まる (確認は消費側で取る)。$Latest は Get-WslUpdateStatus が返した最新版。
#   'skipped-from-wsl'  WSL から起動されているので実行しない (呼び出し元ごと止まるため)
#   'updated'           $Latest 以上になった
#   'not-yet-available' 成功したが版が上がらない。GitHub で公開されてから wsl --update で取れるように
#                       なるまでずれることがある (wsl --update は --web-download を取らない) ので、
#                       失敗ではなく「まだ配信されていない」として扱う
#   'failed'            wsl --update が非 0 で終わった
function Update-WslPackage {
    param([Parameter(Mandatory)][string]$Latest)
    if (Test-LaunchedFromWsl) { return 'skipped-from-wsl' }
    # wsl.exe の進捗は画面へ流す。パイプラインに残すと戻り値に混ざる。wsl.exe は既定で UTF-16 を出し、
    # 1 文字ごとに null が挟まって表示が崩れるので、WSL_UTF8=1 で UTF-8 にする (終わったら元へ戻す)。
    $prevUtf8 = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try {
        Invoke-Quiet { & wsl.exe --update | Out-Host }
        $code = $LASTEXITCODE
    } finally {
        $env:WSL_UTF8 = $prevUtf8
    }
    if ($code -ne 0) { return 'failed' }
    $now = (Get-WslPackageVersion) -as [version]
    $target = $Latest -as [version]
    if ($now -and $target -and $now -ge $target) { return 'updated' }
    return 'not-yet-available'
}
