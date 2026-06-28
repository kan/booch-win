# booch-win

Windows 開発環境のブートストラップを担う公開リポジトリ。

現状の役割は **「素の Windows から private な dotfiles を入れて `dotfiles-win setup` が走る
状態までを 1 コマンドで持っていく」ワンライナー bootstrap（`win.ps1`）のホスト**。

> Linux 側の [booch](https://github.com/kan/booch)（Bash 製・WSL2/Ubuntu 向け）の Windows 版に
> あたる位置づけ。ただし booch とは別実装（PowerShell / winget ベース）で、コードは共有せず
> **規約（責務分離・doctor 出力・result 語彙）のみ共有**する。

## 使い方（ワンライナー）

git すら入っていない素の Windows で、PowerShell（管理者不要）から:

```powershell
irm https://raw.githubusercontent.com/kan/booch-win/main/win.ps1 | iex
```

これだけで次が順に走る:

1. `winget`（App Installer）の確認
2. `git` / `gh`（GitHub CLI）を winget で導入（無い場合のみ＝冪等）
3. 現セッションの PATH を再解決して `git` / `gh` を即利用可能にする
4. `gh auth login`（ブラウザ/デバイスフロー）で GitHub 認証
5. private な dotfiles を clone（既存なら pull）
6. `dotfiles-win.ps1 setup` へ委譲（winget 群導入・設定同期・UAC 昇格は dotfiles-win 本体が担う）

### パラメータ付きで使う

`irm | iex` ではパラメータを渡せないため、明示指定したい場合はスクリプトを変数に取り込んで呼ぶ:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/kan/booch-win/main/win.ps1))) -Dir 'C:\path\to\dotfiles' -Repo 'kan/dotfiles'
```

| パラメータ | 既定 | 説明 |
|---|---|---|
| `-Dir`  | `$HOME\dotfiles` | dotfiles の clone 先 |
| `-Repo` | `kan/dotfiles`   | clone 対象リポジトリ（`owner/name`） |

## 設計上の注意

- **Windows PowerShell 5.1 互換で書く**: 素の Windows は `pwsh` 未導入のため、bootstrap は 5.1 で
  動く構文に限定する（`pwsh` は dotfiles-win 側で winget 導入される）。
- **`irm | iex` は ExecutionPolicy を変更せず動く**（ファイル実行ではないため）。
- **冪等**: 各ステップ「無ければ入れる / 既存なら pull」。再実行で壊れない。

## 将来

Windows 側の汎用ブートストラップ処理（winget 導入ルーチン・設定同期エンジン・doctor フレーム等）を
OSS 化する需要が出た段階で、その受け皿をこのリポジトリに置く想定。現時点では dotfiles リポジトリ内に
留め、ここには移設しない。

## ライセンス

MIT
