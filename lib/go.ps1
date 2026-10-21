#Requires -Version 5.1
#
# lib/go.ps1: 汎用機構 — Go 本体 (go.dev の zip) の導入と更新、go install によるツール導入
#
# dotfiles-win.ps1 から dot-source される。何を入れるか ($GoPackages) は
# 個人選択なので dotfiles-win.config.ps1。
#
# Go 本体は winget (GoLang.Go) を経由せず、go.dev の配布一覧から直接入れる。winget の
# マニフェストは go.dev の MSI を指しているだけで、掲載は検証待ちで遅れることがある
# (セキュリティ修正を含むパッチ版が 1 か月以上載らなかった)。
#
# 入れるのは MSI ではなく zip で、ユーザー領域 (既定は %LOCALAPPDATA%\Programs\Go) へ展開する。
# MSI は約 1.6 万ファイルを旧版の削除と新版の導入で 2 回処理するので、パッチ版の更新に 10 分以上
# かかる (実測 11 分半)。zip を tar.exe で一時フォルダへ展開して差し替えると 30 秒ほどで終わる
# (Linux 版 booch の jobs/go.sh と同じ手順)。ユーザー領域なので管理者権限も要らない。
# MSI で入れた Go (winget の GoLang.Go を含む) が残っていれば、zip の導入が済んでから削除する
# (削除だけは管理者権限が要る)。Machine の PATH はユーザーの PATH より先に引かれるので、残すと
# 古い MSI 版の go が使われ続ける。
# 依存: Invoke-Download (lib/download.ps1)、Get-EffectiveTimeout / Test-IsElevated
# (lib/system.ps1)、Add-UserPathEntry / Update-SessionPath (lib/winget.ps1)。entry が全 lib を
# まとめて dot-source する。
#
# テスト用の継ぎ目 (seam):
#   Get-GoRelease            go.dev の配布一覧から最新の安定版を引く (ネットワーク)
#   Get-GoInstalledVersion   PATH で見つかる go の版 (go version)
#   Get-GoDirVersion         展開先の版 (VERSION ファイル)
#   Get-GoArch               配布物のアーキ名
#   Get-GoMsiProduct         MSI で入れた Go の登録 (レジストリ)
#   Get-GoPathBin            go install の出力先 (go env)
#   Save-GoArchive           zip の取得 (ネットワーク)
#   Expand-GoArchive         zip の展開 (副作用)
#   Invoke-GoMsiUninstall    msiexec /x の実行 (副作用)。終了コードを返す

# go.dev の配布一覧から最新の安定版を返す。失敗時は $null。
# 返すのは version ('go1.X.Y') と files (filename / os / arch / kind / sha256 の配列) を持つ項目。
# 一覧はサポート中の系列 (例: 1.27.x と 1.26.y) を並べて返すので、並び順に頼らず版が最大のものを選ぶ。
function Get-GoRelease {
    $best = $null
    $bestVer = $null
    try {
        $list = Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json' `
            -UseBasicParsing -TimeoutSec (Get-EffectiveTimeout $Script:ApiTimeoutSec)
        foreach ($r in @($list)) {
            if (-not $r.stable) { continue }
            $ver = ConvertTo-GoVersion ([string]$r.version)
            if ($ver -and (-not $bestVer -or $ver -gt $bestVer)) {
                $best = $r
                $bestVer = $ver
            }
        }
    } catch {}
    return $best
}

# 最新の安定版 ('go1.X.Y') を返す (失敗時は '')。doctor の更新有無表示用。
function Get-GoLatestVersion {
    $release = Get-GoRelease
    if ($release) { return [string]$release.version }
    return ''
}

# 導入済みの版 ('go1.X.Y') を返す (未導入なら '')。
# GOTOOLCHAIN=local で呼ぶ。素の go version は、GOTOOLCHAIN の設定やカレントディレクトリの
# go.mod / go.work の toolchain 行で切り替わった先の版を返すので (取得まで走りうる)、本体の版にならない。
function Get-GoInstalledVersion {
    if (-not (Test-Cmd 'go')) { return '' }
    $prev = $env:GOTOOLCHAIN
    $env:GOTOOLCHAIN = 'local'
    try {
        $raw = Invoke-Quiet { & go version 2>$null | Select-Object -First 1 }
    } catch {
        return ''
    } finally {
        $env:GOTOOLCHAIN = $prev
    }
    # 出力は「go version go1.X.Y windows/amd64」。3 つ目が版。
    $parts = @(($raw -as [string]) -split '\s+')
    if ($parts.Count -ge 3) { return $parts[2] }
    return ''
}

# Install-Go の既定の展開先 (%LOCALAPPDATA%\Programs\Go)。
function Get-GoDefaultInstallDir {
    return (Join-Path $env:LOCALAPPDATA 'Programs\Go')
}

# 展開先 $Dir に入っている Go の版 ('go1.X.Y') を返す (無ければ '')。配布物の最上位にある
# VERSION ファイルの 1 行目を読む。go version と違い、PATH の順や GOTOOLCHAIN に左右されない。
function Get-GoDirVersion {
    param([Parameter(Mandatory)][string]$Dir)
    $file = Join-Path $Dir 'VERSION'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    try {
        $line = Get-Content -LiteralPath $file -TotalCount 1 -ErrorAction Stop
    } catch {
        return ''
    }
    $line = ([string]$line).Trim()
    if ($line -match '^go\S+$') { return $line }
    return ''
}

# go.dev の配布物のアーキ名 (amd64 / arm64 / 386) を返す。対応しないアーキなら ''。
# 32bit プロセスから呼ばれたときは OS 側のアーキ (PROCESSOR_ARCHITEW6432) を使う。
function Get-GoArch {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        'x86'   { return '386' }
    }
    return ''
}

# 'go1.X.Y' / 'go1.X' を [version] にする。rc や beta など比較できない表記は $null。
function ConvertTo-GoVersion {
    param([string]$Version)
    if ($Version -match '^go(\d+(\.\d+){1,2})$') { return [version]$Matches[1] }
    return $null
}

# go.dev の zip を $OutFile へ取得する。
function Save-GoArchive {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$OutFile
    )
    # zip は 70 MB を超える。$Script:JobTimeoutSec は取得全体の上限 (curl の --max-time) になるので、
    # そのままだと遅い回線で毎回切れる。5 倍まで待つ。
    Invoke-Download -Uri "https://go.dev/dl/$FileName" -OutFile $OutFile `
        -TimeoutSec (Get-EffectiveTimeout ($Script:JobTimeoutSec * 5))
}

# zip を $Destination へ展開する。失敗したら例外を投げる。
# Windows 10 1803 以降に同梱の tar.exe (bsdtar) を使う (Expand-Archive は 1.6 万ファイルの展開に数分かかる)。
function Expand-GoArchive {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $ZipPath -C $Destination
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed (exit $LASTEXITCODE)" }
}

# フォルダを中身ごと消す (無ければ何もしない。失敗しても例外は投げない)。Go の配布物は約 1.6 万
# ファイルあり、Remove-Item -Recurse では十数秒かかるので cmd の rd を使う。
function Remove-GoTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    & (Join-Path $env:SystemRoot 'System32\cmd.exe') /d /c rd /s /q $Path 2>$null | Out-Null
}

# MSI で入れた Go (go.dev の MSI。winget の GoLang.Go も同じ MSI) の登録を返す。
# 返すのは ProductCode ('{GUID}') と Version を持つ項目の配列 (無ければ空)。
function Get-GoMsiProduct {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $found = @()
    foreach ($k in $keys) {
        $items = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Go Programming Language*' -and $_.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$' }
        foreach ($i in @($items)) {
            $found += [pscustomobject]@{ ProductCode = [string]$i.PSChildName; Version = [string]$i.DisplayVersion }
        }
    }
    return $found
}

# MSI 版の Go を無人で削除し、msiexec の終了コードを返す (0 = 成功、3010 = 成功だが再起動が要る)。
# msiexec は System32 のフルパスで呼ぶ (管理者権限で動くので、PATH 上の同名の実行ファイルを拾わない)。
function Invoke-GoMsiUninstall {
    param([Parameter(Mandatory)][string]$ProductCode)
    $proc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
        -ArgumentList @('/x', $ProductCode, '/qn', '/norestart') `
        -Wait -PassThru
    return $proc.ExitCode
}

# $InstallDir を zip の中身で差し替える。失敗したら例外を投げる。既存の $InstallDir は元に戻し、
# 戻せなかったときは退避先 (.<leaf>-old-<id>) を消さずに残す (次の実行がそこから戻す)。
# 一時フォルダは $InstallDir と同じ親に作る (同じボリュームなので、差し替えはフォルダ名の変更で済む)。
# 前回の実行が途中で止まって残した一時フォルダは、ここで片付ける。$InstallDir が無く退避先だけが
# 残っているなら (退避と差し替えの間で止まった)、それが旧版の唯一のコピーなので先に戻す。
function Update-GoDir {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$InstallDir
    )
    $parent = Split-Path -Parent $InstallDir
    $leaf   = Split-Path -Leaf $InstallDir
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $leftovers = @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ".$leaf-new-*" -or $_.Name -like ".$leaf-old-*" })
    $orphan = $leftovers | Where-Object { $_.Name -like ".$leaf-old-*" } | Select-Object -First 1
    if ($orphan -and -not (Test-Path -LiteralPath $InstallDir)) {
        Move-Item -LiteralPath $orphan.FullName -Destination $InstallDir -ErrorAction SilentlyContinue
    }
    foreach ($d in $leftovers) { Remove-GoTree -Path $d.FullName }

    $id    = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $parent ".$leaf-new-$id"
    $old   = Join-Path $parent ".$leaf-old-$id"
    $keepOld = $false
    try {
        Expand-GoArchive -ZipPath $ZipPath -Destination $stage
        # 配布物の最上位は go\。中身が揃っていなければ差し替えない。
        $newRoot = Join-Path $stage 'go'
        if (-not (Test-Path -LiteralPath (Join-Path $newRoot 'bin\go.exe'))) {
            throw 'zip の中に go\bin\go.exe がありません'
        }
        $hadOld = Test-Path -LiteralPath $InstallDir
        if ($hadOld) {
            try {
                Move-Item -LiteralPath $InstallDir -Destination $old -ErrorAction Stop
            } catch {
                throw "既存の $InstallDir を退避できません (go や gopls が実行中かもしれません): $_"
            }
        }
        try {
            Move-Item -LiteralPath $newRoot -Destination $InstallDir -ErrorAction Stop
        } catch {
            if ($hadOld) {
                try {
                    Move-Item -LiteralPath $old -Destination $InstallDir -ErrorAction Stop
                } catch {
                    $keepOld = $true
                    throw "新しい版を置けず、旧版も $InstallDir へ戻せませんでした (旧版は $old に残っています): $_"
                }
            }
            throw
        }
    } finally {
        Remove-GoTree -Path $stage
        if (-not $keepOld) { Remove-GoTree -Path $old }
    }
}

# go install の出力先 (GOBIN、無ければ GOPATH の先頭の bin) を返す。$GoExe を実行できなければ ''。
function Get-GoPathBin {
    param([Parameter(Mandatory)][string]$GoExe)
    if (-not (Test-Path -LiteralPath $GoExe)) { return '' }
    $prev = $env:GOTOOLCHAIN
    $env:GOTOOLCHAIN = 'local'
    try {
        $lines = @(& $GoExe env GOBIN GOPATH 2>$null)
    } catch {
        return ''
    } finally {
        $env:GOTOOLCHAIN = $prev
    }
    if ($LASTEXITCODE -ne 0 -or $lines.Count -lt 2) { return '' }
    if ($lines[0]) { return [string]$lines[0] }
    $first = @(([string]$lines[1]) -split ';' | Where-Object { $_ })[0]
    if ($first) { return (Join-Path $first 'bin') }
    return ''
}

# MSI 版の Go を削除する。管理者権限が無ければ警告だけ出す。削除できたら $true を返す。
function Remove-GoMsiProduct {
    param([Parameter(Mandatory)][object[]]$Products)
    $vers = ($Products | ForEach-Object { $_.Version }) -join ', '
    if (-not (Test-IsElevated)) {
        Write-Warn "Go: MSI で入れた Go ($vers) が残っています。PATH で先に見つかるので、管理者で再実行すると削除します"
        return $false
    }
    Write-Info "Go: MSI で入れた Go ($vers) を削除します (数分かかります)..."
    $ok = $true
    foreach ($p in $Products) {
        $code = Invoke-GoMsiUninstall -ProductCode $p.ProductCode
        if ($code -ne 0 -and $code -ne 3010) {
            Write-Fail "Go: MSI 版 ($($p.Version)) の削除に失敗 (msiexec exit $code)"
            $ok = $false
        }
    }
    if ($ok) { Write-Ok "Go: MSI 版 ($vers) を削除しました" }
    return $ok
}

# Go 本体を go.dev の zip で $InstallDir (既定は Get-GoDefaultInstallDir) へ導入 / 更新する。
# 未導入なら最新の安定版を入れ、導入済みなら最新の安定版より古いときだけ差し替える。
# 結果は表示し、例外は投げない (利用側の setup を止めない)。
# - 最新版を引けなかった回は何もしない (取得の失敗を「最新」と同じ扱いにしない)
# - 導入済みの版が新しいか、rc など比較できない表記なら触らない (手で入れた版を古い側へ戻さない)。
#   $InstallDir が空のときは PATH 上の go (MSI 版) の版で判定する。MSI 以外の経路で入った go
#   (scoop など) が PATH にあるなら、二重に入れないよう何もしない
# - zip は配布一覧の SHA256 と照合してから展開する。不一致なら展開しない
# - $InstallDir\bin と go install の出力先をユーザーの PATH へ足し、MSI 版が残っていれば削除する
#   (削除は管理者権限があるときだけ)
# 最後に現セッションの PATH をレジストリから組み直す (直後の go install から見えるように)。
function Install-Go {
    param([string]$InstallDir = (Get-GoDefaultInstallDir))
    $release = Get-GoRelease
    if (-not $release) {
        Write-Warn 'Go: 最新版を取得できないため、更新の確認を飛ばします (go.dev/dl)'
        return
    }
    $latest  = [string]$release.version
    $current = Get-GoDirVersion -Dir $InstallDir
    $msi     = @(Get-GoMsiProduct)
    $judged  = if ($current) { $current } else { Get-GoInstalledVersion }
    if (-not $current -and $judged -and $msi.Count -eq 0) {
        # MSI 以外 (scoop や手で展開したもの) で入った go。二重に入れると GOROOT が競合するので触らない。
        Write-Ok "Go: $judged ($InstallDir ではなく別の経路で入っているので、そのままにします)"
        return
    }
    if ($judged -and $judged -ne $latest) {
        $cur = ConvertTo-GoVersion $judged
        $new = ConvertTo-GoVersion $latest
        if (-not $cur -or -not $new -or $cur -gt $new) {
            Write-Ok "Go: $judged (最新の安定版は $latest。導入済みの版を古い側へ戻さないので、そのままにします)"
            return
        }
    }

    $what = $null
    if ($current -ne $latest) {
        $what = if ($judged) { "$judged → $latest" } else { $latest }
        $arch = Get-GoArch
        $file = @($release.files) |
            Where-Object { $_.os -eq 'windows' -and $_.arch -eq $arch -and $_.kind -eq 'archive' } |
            Select-Object -First 1
        if (-not $arch -or -not $file -or -not $file.sha256 -or $file.filename -notmatch '^go[\w.\-]+\.zip$') {
            Write-Fail "Go: $latest の zip が配布一覧に見つかりません (arch: $arch)"
            return
        }

        Write-Info "Go: $what を $InstallDir へ導入します ($($file.filename))..."
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('go-archive-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
        try {
            $zip = Join-Path $tmpDir $file.filename
            Save-GoArchive -FileName $file.filename -OutFile $zip
            $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            if ($actual -ne [string]$file.sha256) {
                throw "SHA256 が配布一覧と一致しません (expected $($file.sha256), actual $actual)"
            }
            Update-GoDir -ZipPath $zip -InstallDir $InstallDir
        } catch {
            Write-Fail "Go: $latest の導入に失敗: $_"
            return
        } finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Add-UserPathEntry -Path (Join-Path $InstallDir 'bin') | Out-Null
    $msiLeft = $msi.Count -gt 0 -and -not (Remove-GoMsiProduct -Products $msi)
    # go install の出力先も PATH に置く。MSI は導入時にこれをユーザーの PATH へ足し、削除時に一緒に消すので、
    # 移行の回に足し直さないと gopls などが見つからなくなる。
    $gopathBin = Get-GoPathBin -GoExe (Join-Path $InstallDir 'bin\go.exe')
    if ($gopathBin) { Add-UserPathEntry -Path $gopathBin | Out-Null }
    Update-SessionPath

    $after = Get-GoInstalledVersion
    if ($after -ne $latest) {
        if ($msiLeft) { return }  # 理由 (MSI 版が先に見つかる) は Remove-GoMsiProduct が表示済み
        Write-Warn "Go: $InstallDir は $latest ですが、go version が $latest を返しません (現在: $after)。PATH で別の go が先に見つかっていないか確認してください"
    } elseif ($what) {
        Write-Ok "Go: $what"
    } else {
        Write-Ok "Go: $latest (up to date)"
    }
}

# Go モジュールプロキシから最新版 (semver タグ) を返す (失敗時は '')。doctor の更新有無
# 表示用。$Module は "golang.org/x/tools/gopls" のようなモジュールパス。go コマンドを
# 使わないのは、go list がモジュールキャッシュとネットワークの両方に依存して待ち時間が
# 読めないため。$Script:ApiTimeoutSec / Get-EffectiveTimeout はエントリ側。
function Get-GoModuleLatestVersion {
    param([Parameter(Mandatory)][string]$Module)
    try {
        $resp = Invoke-RestMethod -Uri "https://proxy.golang.org/$Module/@latest" `
            -UseBasicParsing -TimeoutSec (Get-EffectiveTimeout $Script:ApiTimeoutSec)
        if ($resp.Version) { return [string]$resp.Version }
    } catch {}
    return ''
}

# go install <Package> でツールを導入/更新する。go が無ければ失敗を表示。
function Install-GoPackage {
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Cmd,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Cmd 'go')) {
        Write-Fail "go が見つからないため $Label をインストールできません"
        return
    }
    if (Test-Cmd $Cmd) {
        Write-Ok "${Label}: already installed"
        Write-Info 'Updating...'
    } else {
        Write-Info "Installing ${Label}..."
    }
    & go install $Package
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "${Label}: installed/updated"
    } else {
        Write-Fail "${Label}: install failed"
    }
}
