#Requires -Version 5.1
#
# dotfiles-win.config.ps1: 個人選択 (何を入れるか)
#
# dotfiles-win.ps1 (汎用機構) から dot-source される。ここには「個人固有の選択」= 同期する
# ファイル・導入する winget パッケージ・doctor で見るツールの宣言データだけを置く。仕組み
# (同期エンジン・winget 導入ルーチン等) は booch-win の lib 側にある。
#
# 下記はサンプル。自分の環境に合わせて足す/消す。

# 同期対象: repo 相対パス Repo → 配備先 Dest。機械固有値を含むなら Transform を付け、
# 変換は booch-win の lib/sync.ps1 に足す。
$Script:SyncPairs = @(
    @{ Repo = 'git/gitconfig-win'; Dest = (Join-Path $HOME '.gitconfig') }
)

# winget パッケージ: Id は winget の厳密 ID、Cmd は導入確認に使うコマンド名。
# doctor で見るツール ($DoctorTools) と揃えておくと、clean 環境でも setup → doctor が緑になる。
$Script:WingetPackages = @(
    @{ Id = 'Git.Git';    Cmd = 'git' },
    @{ Id = 'GitHub.cli'; Cmd = 'gh' }
)

# doctor で見るツール: Label 表示名 / Cmd 実在判定 / Ver 版数を出す scriptblock。
$Script:DoctorTools = @(
    @{ Label = 'git';  Cmd = 'git';  Ver = { (git --version) } },
    @{ Label = 'gh';   Cmd = 'gh';   Ver = { (gh --version)[0] } }
)
