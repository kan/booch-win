#Requires -Version 5.1
#
# lib/claude.ps1: 機構 — Claude Code 本体・marketplace・プラグインの導入と更新
#
# dotfiles-win.ps1 から dot-source される。どのプラグインを有効化するか
# ($ClaudePlugins) は個人選択なので dotfiles-win.config.ps1。

# Claude Code 本体を導入/更新する。導入済みなら claude update、失敗時や
# 未導入時は npm でグローバル導入する (node/npm は winget で導入済み前提)。
function Install-ClaudeCode {
    if (Test-Cmd 'claude') {
        Write-Ok 'Claude Code: already installed'
        Write-Info 'Updating...'
        Invoke-Quiet { & claude update 2>&1 | Out-Null }
        if ($LASTEXITCODE -ne 0 -and (Test-Cmd 'npm')) {
            & npm install -g '@anthropic-ai/claude-code'
        }
    } else {
        if (Test-Cmd 'npm') {
            Write-Info 'Installing Claude Code...'
            & npm install -g '@anthropic-ai/claude-code'
            if ($LASTEXITCODE -eq 0) {
                Write-Ok 'Claude Code: installed'
            } else {
                Write-Fail 'Claude Code: install failed'
            }
        } else {
            Write-Fail 'npm が見つからないため Claude Code をインストールできません'
        }
    }
}

# claude plugin list の出力を 1 つの文字列で返す。判定の使い回し用 (複数
# プラグインを同一スナップショットで判定でき、list 呼び出しを 1 回に抑える)。
function Get-ClaudePluginList {
    return (Invoke-Quiet { & claude plugin list 2>&1 | Out-String })
}

# doctor 向け: 導入済み claude プラグインを claude 行の直下にネストして版付きで列挙する
# (情報表示)。最新比較は単一の取得先が無いため行わない (Linux setup/doctor.sh と同じ思想)。
# claude plugin list を 1 回だけパースし、enabled は緑、それ以外は状態を添えて黄で出す。
# claude 未導入のときは何も出さない (claude ツール行が既に MISSING を示すため)。取得失敗
# のときだけ SKIP 行をネスト表示する。$missing には影響しない (情報表示のため)。
function Show-ClaudePlugins {
    if (-not (Test-Cmd 'claude')) {
        return
    }
    $out = Get-ClaudePluginList
    if (-not $out) {
        Write-Status '  (plugins)' 'SKIP' Yellow 'プラグイン情報を取得できません'
        return
    }
    # 出力は「  ❯ name@marketplace / Version: x / Scope: y / Status: ✔ enabled」の
    # ブロックの繰り返し。name と version を拾い、Status 行で 1 プラグイン分を出す。
    $name = ''; $ver = ''
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '^\s*❯\s+(\S+)') {
            $name = ($Matches[1] -split '@')[0]; $ver = ''
        } elseif ($line -match '^\s*Version:\s*(\S+)') {
            $ver = $Matches[1]
        } elseif ($line -match '^\s*Status:\s*(.+?)\s*$') {
            # 「✔ enabled」等。チェックマークの有無に依らず末尾語を状態として使う。
            $st = ($Matches[1] -split '\s+')[-1]
            if ($st -eq 'enabled') {
                Write-Status "  $name" 'OK' Green $ver
            } else {
                Write-Status "  $name" 'WARN' Yellow "$ver ($st)"
            }
        }
    }
}

# 導入済みプラグインの版を返す (未導入・取得失敗なら空文字)。list の
# 「❯ <plugin@marketplace>」行で対象ブロックに入り、そのブロック最初の Version: を読む。
# 別の ❯ 行に入ったら解除するので、Version 行を持たないブロックで次のプラグインの版を
# 誤って拾わない。$Plugin は plugin@marketplace の完全一致で照合する。
function Get-ClaudePluginVersion {
    param(
        [Parameter(Mandatory)][string]$Plugin,   # plugin@marketplace
        [string]$PluginList
    )
    if (-not $PluginList) { $PluginList = Get-ClaudePluginList }
    if (-not $PluginList) { return '' }
    $inBlock = $false
    foreach ($line in ($PluginList -split "`r?`n")) {
        if ($line -match '^\s*❯\s+(\S+)') {
            $inBlock = ($Matches[1] -eq $Plugin)
        } elseif ($inBlock -and $line -match '^\s*Version:\s*(\S+)') {
            return $Matches[1]
        }
    }
    return ''
}

# 渡された scriptblock を実行する間だけ、github SSH→HTTPS 書き換えの GIT_CONFIG_*
# を環境変数に立てる (Linux job_claude と同じ手当て)。プラグイン/マーケットプレイスの
# clone が github SSH (git@github.com:) になると、非対話では ssh.exe + 1Password で
# 鍵に届かず失敗/ハングしうるため、取得の間だけ HTTPS へ寄せる。終了後は元へ戻す。
# claude を & で呼ぶのは finally より前なので $LASTEXITCODE は保全される。
function Invoke-WithGitHubHttps {
    param([Parameter(Mandatory)][scriptblock]$Script)
    $saved = @{
        Count = $env:GIT_CONFIG_COUNT
        Key0  = $env:GIT_CONFIG_KEY_0
        Val0  = $env:GIT_CONFIG_VALUE_0
    }
    try {
        $env:GIT_CONFIG_COUNT   = '1'
        $env:GIT_CONFIG_KEY_0   = 'url.https://github.com/.insteadOf'
        $env:GIT_CONFIG_VALUE_0 = 'git@github.com:'
        & $Script
    } finally {
        $env:GIT_CONFIG_COUNT   = $saved.Count
        $env:GIT_CONFIG_KEY_0   = $saved.Key0
        $env:GIT_CONFIG_VALUE_0 = $saved.Val0
    }
}

# 外部マーケットプレイス (組込みの claude-plugins-official 以外。例: openai-codex) を
# 追加する。冪等 — 既に追加済みなら何もしない。clone は Invoke-WithGitHubHttps 経由で
# HTTPS へ寄せる。$Name は claude plugin marketplace list 上の表示名 (例: openai-codex)。
function Add-ClaudeMarketplace {
    param(
        [Parameter(Mandatory)][string]$Repo,   # owner/name
        [Parameter(Mandatory)][string]$Name    # marketplace list 上の表示名
    )
    if (-not (Test-Cmd 'claude')) { return }
    $list = Invoke-Quiet { & claude plugin marketplace list 2>&1 | Out-String }
    # 行頭の非単語文字 (空白 + 選択マーカー `❯`) を読み飛ばす。Enable-ClaudePlugin と同様。
    if ($list -match "(?m)^[^\w]*$([regex]::Escape($Name))\b") {
        Write-Ok "$Name marketplace: already added"
        return
    }
    Write-Info "Adding $Name marketplace..."
    Invoke-WithGitHubHttps {
        Invoke-Quiet { & claude plugin marketplace add $Repo 2>&1 | Out-Null }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$Name marketplace: added"
    } else {
        Write-Fail "$Name marketplace: add failed (ネットワーク / 認証を確認してください)"
    }
}

# 登録済みの全 marketplace を最新化する (プラグイン有効化より前に呼ぶ)。
#
# Add-ClaudeMarketplace は「未登録なら add」しかしないので、これが無いと marketplace の
# clone が追加時の版のまま古びる。marketplace 側で更新されたプラグイン (スキル・コマンド)
# が、何度 setup を回しても永久に降ってこない状態になる。
#
# 失敗は致命でない (ネットワーク断でも既存の clone のまま続行できる) ので警告に留める。
# clone の fetch を伴うため Invoke-WithGitHubHttps の下で実行する。
function Update-ClaudeMarketplace {
    if (-not (Test-Cmd 'claude')) { return }
    Write-Info 'Updating Claude marketplaces...'
    Invoke-WithGitHubHttps {
        Invoke-Quiet { & claude plugin marketplace update 2>&1 | Out-Null }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'Claude marketplaces: updated'
    } else {
        Write-Warn 'Claude marketplaces: update failed (既存の clone のまま続行します。ネットワーク / 認証を確認してください)'
    }
}

# Claude Code のプラグインを有効化・更新する (claude-plugins-official は組込み
# マーケットプレイスなので add 不要)。
#   - 既にインストール済みかを先に判定し、未導入のときだけ install する。
#     こうすることで install の非ゼロ終了を「既に有効」で握りつぶさず、
#     本当の失敗 (ネットワーク不通 / 未認証 等) を Write-Fail で表面化できる。
#   - 導入済みなら update をかける。install だけだと初回の版で凍結し、marketplace 側で
#     更新されたプラグインが永久に降ってこない (Linux booch の booch_claude_plugin_ensure
#     と対)。update 失敗は致命でないので握り、版が変わったときだけそう報告する。
#   - $PluginList を渡すとその文字列で判定する (未指定なら都度取得)。
# $ShortName は claude plugin list 上の表示名 (例: rust-analyzer-lsp)。
function Enable-ClaudePlugin {
    param(
        [Parameter(Mandatory)][string]$Plugin,
        [Parameter(Mandatory)][string]$ShortName,
        [string]$PluginList
    )
    if (-not (Test-Cmd 'claude')) { return }
    if (-not $PluginList) { $PluginList = Get-ClaudePluginList }
    # ShortName を素の部分一致で見ると、別プラグイン名や説明文に同じ部分文字列が
    # 含まれたとき「有効化済み」と誤認しうる。行頭の非単語文字 (前置空白 + 選択
    # マーカー `❯`) を読み飛ばしてから語境界の厳密一致にし、ShortName は正規表現
    # エスケープしてメタ文字を無効化する。`^\s*` だと `❯ ` を越えられず常に不一致に
    # なる (= 毎回再 install を試みる) ため `^[^\w]*` を使う。
    if ($PluginList -match "(?m)^[^\w]*$([regex]::Escape($ShortName))\b") {
        # 版は update の前後で取り直す ($PluginList は update 前のスナップショットなので、
        # 後の版をそこから読むと必ず「変わっていない」になる)。
        $old = Get-ClaudePluginVersion -Plugin $Plugin -PluginList $PluginList
        Invoke-WithGitHubHttps {
            Invoke-Quiet { & claude plugin update $Plugin 2>&1 | Out-Null }
        }
        $new = Get-ClaudePluginVersion -Plugin $Plugin
        if ($old -and $new -and $old -ne $new) {
            Write-Ok "$ShortName plugin: updated ($old -> $new)"
        } elseif ($new) {
            Write-Ok "$ShortName plugin: already enabled ($new)"
        } else {
            Write-Ok "$ShortName plugin: already enabled"
        }
    } else {
        Write-Info "Enabling $ShortName plugin..."
        # 外部 marketplace のプラグインは clone を伴うため、github SSH→HTTPS 書き換えの
        # 下で install する (組込みプラグインでも無害)。
        Invoke-WithGitHubHttps {
            Invoke-Quiet { & claude plugin install $Plugin 2>&1 | Out-Null }
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$ShortName plugin: installed"
        } else {
            Write-Fail "$ShortName plugin: install failed (ネットワーク / 認証を確認してください)"
        }
    }
}
