# booch-win

Windows 開発環境のブートストラップを担う公開リポジトリ。

現在の役割は次の 2 つです。

1. **ワンライナー bootstrap（`win.ps1`）のホスト**: 素の Windows から private な dotfiles を入れて `dotfiles-win setup` が走る状態までを 1 コマンドで持っていく。
2. **dotfiles-win 汎用ライブラリ（`lib/*.ps1`）のホスト**: winget / sync / doctor / GitHub release / 各種ツール導入など、個人設定に依存しない PowerShell 実装を提供する。

> Linux 側の [booch](https://github.com/kan/booch)（Bash 製、WSL2 / Ubuntu 向け）の Windows 版に
> あたる位置づけ。ただし booch とは別実装（PowerShell / winget ベース）で、コードは共有せず
> **規約（責務分離、doctor 出力、result 語彙）だけを共有**する。

## 使い方（ワンライナー）

git すら入っていない素の Windows で、PowerShell（管理者不要）から。対象の dotfiles
リポジトリ（`owner/name`）は環境変数 `BOOCH_WIN_REPO` で渡す（`irm | iex` は引数を
渡せないため env を使う。booch-win は汎用ツールなので特定リポジトリを既定に持たない）:

```powershell
$env:BOOCH_WIN_REPO = 'youraccount/dotfiles'
irm https://raw.githubusercontent.com/kan/booch-win/main/win.ps1 | iex
```

これだけで次が順に走る:

1. `winget`（App Installer）の確認
2. `git` / `gh`（GitHub CLI）を winget で導入（無い場合のみ＝冪等）
3. 現セッションの PATH を再解決して `git` / `gh` を即利用可能にする
4. `gh auth login`（ブラウザ/デバイスフロー）で GitHub 認証
5. private な dotfiles を clone（既存なら pull）
6. `setup-win/dotfiles-win.ps1 setup` へ委譲（winget パッケージの導入、設定の同期、UAC 昇格は dotfiles-win 本体が行う）

### 設定（環境変数）

設定はすべて環境変数で渡す。win.ps1 は **param ブロックを持たない**。Windows PowerShell 5.1 の
`irm | iex`（文字列を Invoke-Expression で評価）は、版によって先頭の `param(...)` を解釈できず
「代入式が無効」等のパースエラーになる。env だけで動かせば、版に関係なく 5.1 で起動できる。

```powershell
$env:BOOCH_WIN_REPO = 'youraccount/dotfiles'   # 必須
$env:BOOCH_WIN_DIR  = 'C:\path\to\dotfiles'    # 任意（既定は %USERPROFILE%\dotfiles）
irm https://raw.githubusercontent.com/kan/booch-win/main/win.ps1 | iex
```

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `BOOCH_WIN_REPO` | （なし） | clone 対象リポジトリ（`owner/name`）。未指定ならエラー終了 |
| `BOOCH_WIN_DIR`  | `$HOME\dotfiles` | dotfiles の clone 先 |
| `BOOCH_WIN_NORUN` | （なし） | `1` で main を実行せず関数だけ読み込む（テスト用） |

## 設計上の注意

- **Windows PowerShell 5.1 互換で書く**。素の Windows には `pwsh` が入っていないので、bootstrap は
  5.1 で動く構文に限定する（`pwsh` は dotfiles-win 側が winget で導入する）。
- **`irm | iex` は ExecutionPolicy を変更せず動く**（ファイル実行ではないため）。
- 各ステップを冪等にする。「無ければ入れる / 既存なら pull」なので、再実行しても同じ状態に収束する。

## `lib/` の位置づけ

`lib/*.ps1` は dotfiles-win から dot-source される汎用処理です。

- `common.ps1`: 出力ヘルパーと共通ユーティリティ
- `sync.ps1`: repo ↔ 配備先の同期エンジン（`Mode = 'Deploy'` を付けたペアは片方向）
- `cleanup.ps1`: 一時ファイル / ツールキャッシュ / WSL と Tauri の掃除、WSL vhdx の compact、
  放置された git worktree の prune
- `git.ps1`: 複数 git repo の一括 ff-only pull（許可ブランチ外の repo と dirty な repo は触らない）
- `autoremove.ps1`: 宣言から外れた Claude プラグイン / marketplace / codex skill の掃除
  （`-ClaudeConfigDirs` に複数の config dir を渡せば、アカウントごとに走査する）
- `winget.ps1`: winget 呼び出し、PATH 操作、導入判定、追跡外監査、設定 (settings.json) のキー単位更新
- `doctor.ps1`: doctor 表示フレーム（ツール一覧 / ディスク空き / WSL vhdx サイズ）
- `download.ps1` / `github.ps1`: ダウンロードと GitHub Releases の取得
- `go.ps1` / `rust.ps1` / `npm.ps1` / `textlint.ps1`: 言語ツール導入
- `codex.ps1` / `claude.ps1`: AI 開発ツールの導入と設定補助。Codex CLI は公式インストーラー
  （`install.ps1`）を子プロセスで実行して入れる（`Install-Codex [-Version <x.y.z>]`）。codex.exe 単体では
  付随する実行ファイルが揃わず動かないため。見える bin dir はインストーラーの既定
  （`%LOCALAPPDATA%\Programs\OpenAI\Codex\bin`。`CODEX_INSTALL_DIR` で変更可）で、以前の版が置いた
  `~\.local\bin\codex.exe` は導入の成功後に削除する（再試行用に `Clear-LegacyCodexBinary` を単独でも呼べる）。
  `-Version` を省略するとインストーラーの latest になり、GitHub の最新タグとずれることがあるので、
  `Get-CodexLatestVersion` と比べてから入れるなら、その版を渡す。
  更新も同じインストーラーで行い、current と直前の版より古い版は削除する。claude CLI は必ず
  `Get-ClaudeCommand`（実体解決）経由で呼ぶ（同名の関数やエイリアスが先に解決されるのを避けるため）。
  config dir（= アカウント）の切り替えは `Set-ClaudeConfigDir` / `Invoke-WithClaudeConfigDir`
- `font.ps1` / `openvpn.ps1` / `system.ps1`: Windows 環境補助
- `keyboard.ps1`: キーボード remap（Scancode Map）と入力方式（TSF）の設定、TIP 登録の判定
- `wsl.ps1`: WSL2 とディストロの導入
- `apidoc.ps1`: `lib/*.ps1` のヘッダと公開関数を抽出して `booch-win help` を組み立てる
- `bootstrap.ps1`: 消費側から booch-win を取り込むためのルート解決とロード対象一覧
- `scaffold.ps1`: booch-win を使う repo の雛形を `templates/` から生成する

個人や環境に固有の「何を入れるか」は dotfiles 側の `setup-win/dotfiles-win.config.ps1` に置き、ここには置きません。

### 消費側からの取り込み（`bootstrap.ps1`）

dotfiles-win のようなエントリスクリプトは、`lib/bootstrap.ps1` を dot-source して booch-win を
取り込みます。`bootstrap.ps1` を読む前に、ルートが決まっている必要があります。そのためエントリは、
`Resolve-BoochWinRoot` と同じ候補順（`BOOCH_WIN_ROOT` → `vendor/booch-win` → `../booch-win`）で
`lib/bootstrap.ps1` のある場所を自前で探します。見つけたルートから bootstrap と lib を読みます
（`booch-win scaffold` が生成する `dotfiles-win.ps1` がこの形です）。

```powershell
# $root: 上の候補順で lib/bootstrap.ps1 が見つかった booch-win のルート
. (Join-Path $root 'lib\bootstrap.ps1')
foreach ($f in Get-BoochWinLibFile -Root $root) { . $f }   # ★エントリのトップレベルで dot-source
```

- `Resolve-BoochWinRoot`: `BOOCH_WIN_ROOT` → `vendor/booch-win` → 隣の `../booch-win` →
  旧構成（`-SetupWinDir` に lib を同梱）の順にルートを解決する。Linux 側 booch の `BOOCH_ROOT`
  解決と対称で、エントリが自前で探すときの候補順もこれに合わせる。
- `Get-BoochWinLibFile`: dot-source すべき `lib/*.ps1`（`bootstrap.ps1` と `apidoc.ps1` を除き、
  `common.ps1` を先頭にした一覧）を返す。新しい lib を足せば、消費側を変えずにロード対象へ入る。
- **ロードは必ずエントリのトップレベルで回す**（1 関数に隠蔽しない）。lib はエントリが定義する
  `$Script:` 変数を参照する設計で、関数内 dot-source では呼び出し元スコープへ伝播しないため。
  詳細は `booch-win help bootstrap`。

## API を引く（`booch-win help`）

各 `lib/*.ps1` の公開 API は、ソースを開かずに補助 CLI `bin/booch-win.ps1` で確認できます
（Linux 側 booch の `booch help` に対応）。出力はソース（冒頭ヘッダ＋トップレベル関数）から
生成するので、別途 API doc をメンテしません。

```powershell
./bin/booch-win.ps1 help            # モジュール一覧（name + 1 行説明）
./bin/booch-win.ps1 help winget     # winget.ps1 のヘッダ全文 + 公開関数シグネチャ
./bin/booch-win.ps1 help sync
./bin/booch-win.ps1 version         # バージョン（VERSION ファイル）
```

help がそのまま API doc になるよう、`lib/*.ps1` を足したり変えたりするときは次を守ります。

- **ファイル冒頭ヘッダの最初の非空行を、自己完結した 1 行説明にする**（`lib/<name>.ps1: 概要` の
  形式。索引に出る）。
- **公開したい処理はトップレベル関数**にする（PowerShell は dot-source で全関数が見えるため、
  prefix ではなくトップレベルかどうかで公開面を判断する。関数内のネスト定義は help に出ない）。
- 型制約付き引数は `[type]$name` として自動併記される。

新しい `lib/*.ps1` を足せば `booch-win help` に自動で載ります（登録簿の更新は不要）。抽出規約の
詳細は `lib/apidoc.ps1` の冒頭コメントを正本にします。

## 開発・テスト

- Tier1（自動、CI）: `tests/*.Tests.ps1`（Pester 5。winget / gh / git などをモックしてロジックを検証）と
  PSScriptAnalyzer、構文 parse を GitHub Actions（`windows-latest`）で実行する。ローカルでは次のとおり:

  ```powershell
  Invoke-Pester -Path ./tests
  $paths = @('./win.ps1') + @(Get-ChildItem ./lib, ./bin -Filter '*.ps1' | ForEach-Object FullName); foreach ($path in $paths) { Invoke-ScriptAnalyzer -Path $path -Settings ./PSScriptAnalyzerSettings.psd1 }
  ```

- Tier2（手動、実環境）: 実 winget、実認証、実 clone までのスモークは、使い捨ての
  Windows Sandbox で行う。手順は [`tests/sandbox/manual-smoke.md`](tests/sandbox/manual-smoke.md)。
  ホスト型 CI には winget が無く、対話認証と UAC も通せないので、ここは自動化できない。

## 雛形を生成する（`booch-win scaffold`）

booch-win を使う新しい dotfiles-win リポジトリの骨組みを生成できる（Linux 側 booch の
`booch init` に対応）。生成物は `templates/dotfiles-win/` の複製で、**既存ファイルは上書き
しない**（冪等。`-Force` で上書き）。git は触らないので、submodule 追加などは生成された
README の手順に従う。

```powershell
./bin/booch-win.ps1 scaffold dotfiles-win -Path C:\path\to\new-dotfiles
```

生成されるのは `setup-win/{dotfiles-win.ps1, dotfiles-win.config.ps1, dotfiles-win,
dotfiles-win.cmd}`、`README.md`、`CLAUDE.md`、`.gitattributes` の最小構成。生成直後に booch-win を
`vendor/booch-win` へ submodule 追加すれば `setup-win/dotfiles-win.ps1 help` / `doctor` が
動く（開発中は `BOOCH_WIN_ROOT` で booch-win の場所を明示してもよい）。生成される
`dotfiles-win.ps1` は「booch-win を解決して lib をロードし、config を読んで dispatch する」
最小スケルトンで、`setup` / `sync` は用途に合わせて肉付けする前提（TODO コメントあり）。

## リリース

バージョンの正本はルートの [`VERSION`](VERSION)（SemVer 1 行）。`booch-win version` と git タグ
`v<...>` をこれに一致させる。リリースは GitHub Releases（タグ + ノート）で行い、配布は
clone / submodule（tarball は付けない）。**消費側（dotfiles-win）は submodule をリリースタグに
pin する**（`vendor/booch-win` を新タグへ進めてコミット）。

手順（バージョン bump は勝手に行わない。指示があってから）:

1. `VERSION` を上げる（SemVer）。`booch-win version` が新版を返すことを確認。
2. `CHANGELOG.md` の `[Unreleased]` を新バージョンの節へ繰り上げ、日付と比較リンクを付ける。
3. 変更をコミット（日本語メッセージ。bump とノートを含む）。
4. タグを打って push: `git tag -a v0.1.0 -m v0.1.0 && git push origin v0.1.0`。
5. リリース作成: `gh release create v0.1.0 --title v0.1.0 --notes "<CHANGELOG の当該節>"`。
6. 消費側の pin を更新（dotfiles の `vendor/booch-win` を新タグへ）。

**タグは annotated（`-a`）で打つ**。`-a` 無しの lightweight タグは `git describe`（`--tags`
無し）から無視される。そのため、消費側が `git submodule status` / `git describe` で pin 先を確認すると
1 つ前のリリースが表示される。過去のタグは lightweight（`v0.1.0`〜`v0.5.1` / `v0.7.0`〜`v0.13.0`）と
annotated が混在している。配布済みのタグを貼り直しても、手元に古いタグを持つ clone は fetch で
更新されず種別が食い違うので、打ち直さずに今後のタグだけを揃える（過去版を pin して確認する側は
`git describe --tags` を使えば混在の影響を受けない）。annotated であることと、`VERSION` がタグ名と
一致することは、`v*` タグの push で `.github/workflows/release-tag.yml` が検査する。打ち間違えれば
このワークフローが失敗する。

## 将来

dotfiles-win のオーケストレーションのうち、sync（`Invoke-BoochWinSync`）、cleanup
（`Invoke-BoochWinCleanup`）、autoremove（`Invoke-BoochWinAutoremove`）の組み立ては、すでに
booch-win 側にある。doctor と setup 全体（UAC 昇格、自己更新、再起動を含む）は利用側に固有の処理が多いので、
当面は利用側のエントリに残す。doctor の汎用フレーム（`Show-ToolList` など）は `lib/doctor.ps1` にある。

## ライセンス

MIT

