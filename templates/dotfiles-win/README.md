# dotfiles-win

Windows 開発環境の設定を管理する private リポジトリ（[booch-win](https://github.com/kan/booch-win)
ベース）。汎用機構（winget 導入 / 設定同期 / doctor 等）は booch-win に任せ、ここには個人固有の
選択（何を入れる・何を同期する）だけを置く。

## セットアップ

booch-win を submodule として取り込む（`vendor/booch-win`）。**リリースタグに pin する**。

```powershell
git submodule add https://github.com/kan/booch-win vendor/booch-win
git -C vendor/booch-win fetch --tags
git -C vendor/booch-win checkout v0.1.0   # 最新のリリースタグに合わせる
git add .gitmodules vendor/booch-win
git commit -m "booch-win を vendor に追加（v0.1.0 に pin）"
```

> 開発中に booch-win 本体をいじる場合は、隣に clone（`../booch-win`）を置くか、環境変数
> `BOOCH_WIN_ROOT` で場所を明示すると submodule より優先される。

## 使い方

```powershell
setup-win/dotfiles-win.ps1 help     # ヘルプ
setup-win/dotfiles-win.ps1 doctor   # ツール/設定のチェック
setup-win/dotfiles-win.ps1 sync     # 設定ファイルの同期（repo → 環境）
setup-win/dotfiles-win.ps1 setup    # winget 導入 + 同期（既定）
```

git bash からは拡張子なしの `dotfiles-win` ラッパー、PowerShell / cmd からは `dotfiles-win.cmd`
シムでも呼べる（`~/.local/bin` に配備して PATH に置くと便利）。

## 構成

| 区分 | 場所 | 内容 |
|---|---|---|
| 本体 | `setup-win/dotfiles-win.ps1` | 引数 dispatch と最小オーケストレーション |
| 選択 | `setup-win/dotfiles-win.config.ps1` | `$SyncPairs` / `$WingetPackages` / `$DoctorTools` |
| 機構 | `vendor/booch-win/lib/*.ps1` | winget / sync / doctor / … （公開 API は `vendor/booch-win/bin/booch-win.ps1 help`） |

ツールや同期対象を増やすときは、選択値を config に足す。汎用の「やり方」が要るなら booch-win 側に
ヘルパーを足す。`setup-win/` 配下の `.ps1` は UTF-8 BOM + LF で統一する（PS5.1 のファイル直実行で
日本語が化けないため）。
