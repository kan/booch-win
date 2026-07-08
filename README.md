# booch-win

Windows 開発環境のブートストラップを担う公開リポジトリ。

現在の役割は次の 2 つです。

1. **ワンライナー bootstrap（`win.ps1`）のホスト**: 素の Windows から private な dotfiles を入れて `dotfiles-win setup` が走る状態までを 1 コマンドで持っていく。
2. **dotfiles-win 汎用ライブラリ（`lib/*.ps1`）のホスト**: winget / sync / doctor / GitHub release / 各種ツール導入など、個人設定に依存しない PowerShell 実装を提供する。

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
6. `setup-win/dotfiles-win.ps1 setup` へ委譲（winget 群導入・設定同期・UAC 昇格は dotfiles-win 本体が担う）

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

## `lib/` の位置づけ

`lib/*.ps1` は dotfiles-win から dot-source される汎用処理です。

- `common.ps1`: 表示・共通実行ヘルパー
- `sync.ps1`: repo ↔ 配備先の同期エンジン
- `winget.ps1`: winget 呼び出し・導入判定・追跡外監査
- `doctor.ps1`: doctor 表示フレーム
- `download.ps1` / `github.ps1`: ダウンロード・GitHub Releases 取得
- `go.ps1` / `rust.ps1` / `npm.ps1` / `textlint.ps1`: 言語ツール導入
- `codex.ps1` / `claude.ps1`: AI 開発ツール導入・設定補助
- `font.ps1` / `openvpn.ps1` / `system.ps1`: Windows 環境補助
- `apidoc.ps1`: `lib/*.ps1` のヘッダ・公開関数を抽出して `booch-win help` を組み立てる
- `bootstrap.ps1`: 消費側から booch-win を取り込むためのルート解決とロード対象一覧

個人・環境固有の「何を入れるか」は dotfiles 側の `setup-win/dotfiles-win.config.ps1` に置き、ここには置きません。

### 消費側からの取り込み（`bootstrap.ps1`）

dotfiles-win のようなエントリスクリプトは、`lib/bootstrap.ps1` を dot-source して次の 2 関数で
booch-win を取り込みます。

```powershell
. (Join-Path $boochWinRoot 'lib\bootstrap.ps1')
$root = Resolve-BoochWinRoot -DotfilesDir $DotfilesDir -SetupWinDir $SetupWinDir
foreach ($f in Get-BoochWinLibFile -Root $root) { . $f }   # ★エントリのトップレベルで dot-source
```

- `Resolve-BoochWinRoot`: `BOOCH_WIN_ROOT` → `vendor/booch-win` → sibling `../booch-win` → legacy の
  順にルートを解決する（Linux 側 booch の `BOOCH_ROOT` 解決と対称）。
- `Get-BoochWinLibFile`: dot-source すべき `lib/*.ps1`（`bootstrap.ps1` / `apidoc.ps1` を除く、
  `common.ps1` 先頭）を返す。新しい lib を足せば消費側を変えずに自動で載る。
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

help がそのまま API doc になるよう、`lib/*.ps1` を足す・変える際は次を守ります。

- **ファイル冒頭ヘッダの最初の非空行を、自己完結した 1 行説明にする**（`lib/<name>.ps1: 概要` の
  形式。索引に出る）。
- **公開したい処理はトップレベル関数**にする（PowerShell は dot-source で全関数が見えるため、
  prefix ではなくトップレベルかどうかで公開面を判断する。関数内のネスト定義は help に出ない）。
- 型制約付き引数は `[type]$name` として自動併記される。

新しい `lib/*.ps1` を足せば `booch-win help` に自動で載ります（登録簿の更新は不要）。抽出規約の
詳細は `lib/apidoc.ps1` の冒頭コメントを正本にします。

## 開発・テスト

- **Tier1（自動・CI）**: `tests/win.Tests.ps1`（Pester 5、winget/gh/git をモックしロジック検証）と
  PSScriptAnalyzer・構文 parse を GitHub Actions（`windows-latest`）で実行。ローカルでは:

  ```powershell
  Invoke-Pester -Path ./tests
  $paths = @('./win.ps1') + @(Get-ChildItem ./lib, ./bin -Filter '*.ps1' | ForEach-Object FullName); foreach ($path in $paths) { Invoke-ScriptAnalyzer -Path $path -Settings ./PSScriptAnalyzerSettings.psd1 }
  ```

- **Tier2（手動・実環境）**: 実 winget・実認証・実 clone までのスモークは使い捨ての
  Windows Sandbox で行う。手順は [`tests/sandbox/manual-smoke.md`](tests/sandbox/manual-smoke.md)。
  ホスト型 CI は winget 不在・対話認証・UAC のため不可。

## 将来

dotfiles-win のオーケストレーション（setup / doctor / sync / cleanup の組み立て）は段階的に dotfiles 側からこちらへ寄せる。まずは `lib/*.ps1` を公開基盤として切り出し、dotfiles 側は config とエントリに集中させる。

## ライセンス

MIT

