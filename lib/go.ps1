#Requires -Version 5.1
#
# lib/go.ps1: 汎用機構 — Go 本体 (go.dev の MSI) の導入と更新、go install によるツール導入
#
# dotfiles-win.ps1 から dot-source される。何を入れるか ($GoPackages) は
# 個人選択なので dotfiles-win.config.ps1。
#
# Go 本体は winget (GoLang.Go) を経由せず、go.dev の配布一覧から直接入れる。winget の
# マニフェストは go.dev の MSI を指しているだけで、掲載は検証待ちで遅れることがある
# (セキュリティ修正を含むパッチ版が 1 か月以上載らなかった)。入れる MSI は winget と同じ物
# なので、winget で入れた既存の導入をそのまま上書き更新できる。
# 依存: Invoke-Download (lib/download.ps1)、Get-EffectiveTimeout / Test-IsElevated
# (lib/system.ps1)、Update-SessionPath (lib/winget.ps1)。entry が全 lib をまとめて dot-source する。
#
# テスト用の継ぎ目 (seam):
#   Get-GoRelease            go.dev の配布一覧から最新の安定版を引く (ネットワーク)
#   Get-GoInstalledVersion   導入済みの版 (go version)
#   Get-GoArch               配布物のアーキ名
#   Save-GoInstaller         MSI の取得 (ネットワーク)
#   Invoke-GoInstaller       msiexec の実行 (副作用)。終了コードを返す

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

function Save-GoInstaller {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$OutFile
    )
    # MSI は 60 MB を超える。$Script:JobTimeoutSec は取得全体の上限 (curl の --max-time) になるので、
    # そのままだと遅い回線で毎回切れる。5 倍まで待つ。
    Invoke-Download -Uri "https://go.dev/dl/$FileName" -OutFile $OutFile `
        -TimeoutSec (Get-EffectiveTimeout ($Script:JobTimeoutSec * 5))
}

# MSI を無人で導入し、msiexec の終了コードを返す (0 = 成功、3010 = 成功だが再起動が要る)。
# msiexec は System32 のフルパスで呼ぶ (管理者権限で動くので、PATH 上の同名の実行ファイルを拾わない)。
function Invoke-GoInstaller {
    param([Parameter(Mandatory)][string]$MsiPath)
    $proc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
        -ArgumentList @('/i', "`"$MsiPath`"", '/qn', '/norestart') `
        -Wait -PassThru
    return $proc.ExitCode
}

# Go 本体を go.dev の MSI で導入 / 更新する。未導入なら最新の安定版を入れ、導入済みなら
# 最新の安定版より古いときだけ更新する。結果は表示し、例外は投げない (利用側の setup を止めない)。
# - 最新版を引けなかった回は何もしない (取得の失敗を「最新」と同じ扱いにしない)
# - 導入済みの版が新しいか、rc など比較できない表記なら触らない (手で入れた版を古い側へ戻さない)
# - MSI は配布一覧の SHA256 と照合してから実行する。不一致なら実行しない
# - MSI は全ユーザー向け (Program Files) なので、導入と更新は管理者権限でだけ行う
# 導入後は現セッションの PATH をレジストリから組み直す (直後の go install から見えるように)。
function Install-Go {
    $release = Get-GoRelease
    if (-not $release) {
        Write-Warn 'Go: 最新版を取得できないため、更新の確認を飛ばします (go.dev/dl)'
        return
    }
    $latest  = [string]$release.version
    $current = Get-GoInstalledVersion
    if ($current) {
        if ($current -eq $latest) {
            Write-Ok "Go: $current (up to date)"
            return
        }
        $cur = ConvertTo-GoVersion $current
        $new = ConvertTo-GoVersion $latest
        if (-not $cur -or -not $new -or $cur -gt $new) {
            Write-Ok "Go: $current (最新の安定版は $latest。導入済みの版を古い側へ戻さないので、そのままにします)"
            return
        }
    }
    $what = if ($current) { "$current → $latest" } else { $latest }

    if (-not (Test-IsElevated)) {
        Write-Warn "Go: $what の導入には管理者権限が要ります (管理者で再実行してください)"
        return
    }
    $arch = Get-GoArch
    $file = @($release.files) |
        Where-Object { $_.os -eq 'windows' -and $_.arch -eq $arch -and $_.kind -eq 'installer' } |
        Select-Object -First 1
    if (-not $arch -or -not $file -or -not $file.sha256 -or $file.filename -notmatch '^go[\w.\-]+\.msi$') {
        Write-Fail "Go: $latest の MSI が配布一覧に見つかりません (arch: $arch)"
        return
    }

    Write-Info "Go: $what を導入します ($($file.filename))..."
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('go-installer-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    try {
        $msi = Join-Path $tmpDir $file.filename
        Save-GoInstaller -FileName $file.filename -OutFile $msi
        $actual = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
        if ($actual -ne [string]$file.sha256) {
            throw "SHA256 が配布一覧と一致しません (expected $($file.sha256), actual $actual)"
        }
        $code = Invoke-GoInstaller -MsiPath $msi
        if ($code -ne 0 -and $code -ne 3010) {
            throw "msiexec failed (exit $code)"
        }
    } catch {
        Write-Fail "Go: $latest の導入に失敗: $_"
        return
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Update-SessionPath
    $after = Get-GoInstalledVersion
    if ($after -ne $latest) {
        Write-Warn "Go: 導入は終わりましたが、go version が $latest を返しません (現在: $after)。PATH で別の go が先に見つかっていないか確認してください"
    } elseif ($code -eq 3010) {
        Write-Ok "Go: $what (反映には再起動が要ります)"
    } else {
        Write-Ok "Go: $what"
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
