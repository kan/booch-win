#Requires -Version 5.1
#
# lib/rust.ps1: 汎用機構 — rustup ツールチェイン更新と component 導入
#
# dotfiles-win.ps1 から dot-source される。どの component を入れるか
# ($RustupComponents) は個人選択なので dotfiles-win.config.ps1。詳細は #6。
# rustup の有無は呼び出し側 (Invoke-Setup) が判定してから呼ぶ前提。

# stable ツールチェイン (rustc/cargo) を更新する。winget が更新するのは
# rustup 本体だけで、ツールチェインは rustup update でしか上がらない。
# これが無いと rustup だけ新しくツールチェインが古いまま残る (冪等: 最新なら no-op)。
function Update-RustToolchainStable {
    Write-Info 'Updating Rust toolchain (stable)...'
    Invoke-Quiet { & rustup update stable 2>&1 | Out-Null }
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'Rust toolchain (stable): updated'
    } else {
        Write-Fail 'Rust toolchain (stable): update failed'
    }
}

# rustup component を既定ツールチェインへ追加する。
# rustup の component プロキシ (rust-analyzer 等) は「既定/アクティブな
# ツールチェイン」を解決するため、component はユーザーの既定ツールチェイン
# (nightly 等) に入れる必要がある。
#   1. まず既定ツールチェインへ component 追加を試す（既存の既定を尊重）
#   2. 失敗（既定が未設定）した場合のみ stable を既定にして再試行
#      ＝書き換えても惜しくない「既定なし」状態でだけ stable を default にする
function Add-RustupComponent {
    param([Parameter(Mandatory)][string]$Component)
    Invoke-Quiet { & rustup component add $Component 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) {
        Invoke-Quiet { & rustup default stable 2>&1 | Out-Null }
        Invoke-Quiet { & rustup component add $Component 2>&1 | Out-Null }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "${Component}: installed/updated"
    } else {
        Write-Fail "${Component}: install failed"
    }
}
