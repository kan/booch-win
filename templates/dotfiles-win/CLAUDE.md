# dotfiles-win 開発ノート

このリポジトリは [booch-win](https://github.com/kan/booch-win) の `scaffold` で生成した骨組み。
使い方は [README.md](README.md) が正本。ここは**このリポジトリを編集するときの決めごと**を残す。

## 改行コード / エンコーディング

- `setup-win/` 配下の `.ps1` は **UTF-8 BOM + LF**（PS5.1 のファイル直実行で日本語が化けないため）。
- 改行は原則 **LF 固定**（`.gitattributes` で `* eol=lf`）。bash ラッパー `dotfiles-win` の shebang を
  壊さないため。

### `.cmd` を LF にしている件（既知の判断）

`setup-win/dotfiles-win.cmd` も `.gitattributes` の `*.cmd text eol=lf` により **LF** で管理している。

- 一般には **バッチファイルは CRLF が無難**とされる。cmd.exe は LF のみの `.cmd` で
  `goto :label` のラベル解決に失敗する（"The system cannot find the batch label specified"）
  ことが、特に**ラベルがファイル末尾にある**場合に報告されている。本 `.cmd` は
  `:collect` / `:run` ラベルを引数収集ループに使うため、この構文が該当する。
- それでも LF を採っているのは、(1) リポジトリ全体を LF 固定にして shebang 破損や
  環境差を避ける方針との一貫性、(2) 実運用中の同構成 `.cmd`（LF）が Windows 11 の
  cmd.exe で問題なく動いている実績、(3) 本ファイルのラベルは末尾ではなく中間にあり、
  報告されている失敗条件に当たりにくい、による。
- **もし** cmd.exe / PowerShell から拡張子なし `dotfiles-win` 呼び出しで
  「バッチラベルが見つかりません」が出たら、この `.cmd` を CRLF に切り替える
  （`.gitattributes` を `*.cmd text eol=crlf` にする）ことで解消できる。`.ps1` 本体と
  bash ラッパー経由の呼び出しはこの問題の影響を受けない。
- 上流での検証・方針追跡は [kan/booch-win#8](https://github.com/kan/booch-win/issues/8)。

## 構成の考え方

- 汎用機構（winget/sync/doctor 等の「やり方」）は booch-win 側 `vendor/booch-win/lib/*.ps1`。
- 個人固有の選択（何を入れる/同期する）は `setup-win/dotfiles-win.config.ps1`。
- 本体 `setup-win/dotfiles-win.ps1` は「解決 → lib ロード → config 読み込み → dispatch」の薄い層。
  `setup` / `sync` の中身は用途に合わせて肉付けする（scaffold 直後は最小実装）。
- booch-win はリリースタグに pin する（`vendor/booch-win`）。API は
  `vendor/booch-win/bin/booch-win.ps1 help` で引ける。
