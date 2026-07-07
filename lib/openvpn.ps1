#Requires -Version 5.1
#
# lib/openvpn.ps1: 汎用機構 — OpenVPN 接続定義 (.ovpn) の 1Password からの展開
#
# .ovpn はクライアント秘密鍵・tls-auth 静的鍵をインラインで含むためリポジトリに
# 平文で持たず、1Password の Document として保管する。新規環境では op (1Password CLI)
# で取得し、OpenVPN GUI が読む %USERPROFILE%\OpenVPN\config\ 配下へ配置する。Linux 側
# setup/prepare.sh の Ubuntu Pro トークン取得 (op.exe read) と同じ「機微は 1Password、
# 取れなければ案内へフォールバック」の作法。dotfiles-win.ps1 から dot-source される。
# 選択 (どの item をどこへ) は dotfiles-win.config.ps1 の $OpenVpnConfigs。

# $Configs の各 .ovpn を、宛先が無いときだけ op から展開する (毎回 1Password の
# 承認モーダルを出さない / 冪等)。1Password 側を更新して取り直したいときは環境変数
# DOTFILES_WIN_OPENVPN_FORCE=1 で強制再取得する。
function Install-OpenVpnConfigs {
    param([array]$Configs)

    if (-not $Configs -or $Configs.Count -eq 0) { return }

    Write-Host ''
    Write-Host '--- OpenVPN 接続定義 (1Password) ---'

    if (-not (Test-Cmd 'op')) {
        Write-Warn 'op (1Password CLI) が無いため OpenVPN 定義の展開をスキップします'
        return
    }

    $force = ($env:DOTFILES_WIN_OPENVPN_FORCE -eq '1')

    foreach ($c in $Configs) {
        $dest = $c.Dest
        $name = Split-Path $dest -Leaf

        if ((Test-Path $dest) -and -not $force) {
            Write-Ok "$name : 配置済み (skip)"
            continue
        }

        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        # op 自身にファイルを書かせる (--out-file)。stdout を PowerShell で受けて
        # 書き戻すと UTF-16 化・BOM 付与・CRLF 変換でバイトが化けるため通さない。
        # 一時ファイルへ出して成功時だけ移動し、途中失敗で壊れた .ovpn を残さない。
        $tmp = "$dest.op-tmp"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Invoke-Quiet {
            & op document get $c.OpItem --vault $c.Vault --out-file $tmp --force 2>$null
        }
        if ($LASTEXITCODE -eq 0 -and (Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) {
            Move-Item -Path $tmp -Destination $dest -Force
            Write-Ok "$name : 1Password から展開 ($($c.Vault) / $($c.OpItem))"
        } else {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Write-Warn "$name : 1Password から取得できませんでした (op サインインと item '$($c.OpItem)' in '$($c.Vault)' を確認)"
            Write-Info "手動配置: op document get `"$($c.OpItem)`" --vault `"$($c.Vault)`" --out-file `"$dest`""
        }
    }
}
