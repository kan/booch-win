# booch-win 開発ガイド

booch-win は Windows 向けの再実行可能な開発環境ブートストラップ／同期基盤。Linux 版
[booch](https://github.com/kan/booch) の対（Bash→PowerShell）。**使い方・API の正本は
[README.md](README.md)**。この CLAUDE.md は **booch-win 自体を安全に修正・拡張するための
ルールと tips** に絞る。

背景: dotfiles-win 系スクリプトに混在しがちな汎用処理（winget / sync / bootstrap 等）の
切り出し先。公開物なので、個人固有・業務固有の値や前提を持ち込まない。

---

## 編集前に守る鉄則

1. **冪等性を壊さない**。再実行で壊れない・無駄に再取得しない作りを保つ。バージョン比較・
   存在チェックで skip する既存パターンに合わせる。
2. **改行は LF、`.ps1` は UTF-8 BOM + LF**。PS5.1 のファイル直実行で日本語が化けないため
   BOM を付ける。CRLF を混ぜない。
3. **公開 API は PowerShell の承認済み動詞 + booch-win 名詞**（`Invoke-Winget` /
   `Install-WingetPackages` / `Get-BoochWinLibFile` / `Resolve-BoochWinRoot` など）。公開関数は
   `bin/booch-win.ps1 help <name>` で引ける（ヘッダ + シグネチャをソースから抽出）。関数を
   足すときはファイル冒頭ヘッダの 1 行説明を自己完結にし、help がそのまま API doc になる状態を保つ。
4. **個人固有・業務固有を持ち込まない**。トークン・社内ドメイン・**特定の dotfiles リポジトリ名は
   利用側 dotfiles に置く**。booch-win は汎用部分だけを担う。
   - **`kan/dotfiles`（作者個人の dotfiles）を一切書かない**。コード既定値・コメント・ドキュメント・
     テスト・雛形のいずれにも登場させないこと。対象リポジトリは利用者が渡すもの（`win.ps1` なら
     環境変数 `BOOCH_WIN_REPO`）で、既定に埋め込まない。例示が要るときは中立の
     プレースホルダ（`youraccount/dotfiles` / `<owner>/<name>`）を使う。issue 参照も個人 dotfiles
     リポジトリ（`kan/dotfiles#N`）へリンクしない。
5. **コミット・バージョン bump を勝手にやらない**。コミットメッセージは日本語。

## 構成

- `win.ps1`: 素の Windows から「dotfiles-win setup が走る状態」までを 1 コマンドで持っていく
  ブートストラップ（`irm | iex`）。**自己完結**（booch-win の lib を source できない前提）で、
  **Windows PowerShell 5.1 互換**に限定する（素の環境に pwsh は無い）。**param ブロックを持たず
  設定は環境変数**（`BOOCH_WIN_REPO`（必須）/ `BOOCH_WIN_DIR` / `BOOCH_WIN_NORUN`）で受ける — PS5.1 の
  `irm|iex` は版によって先頭 `param(...)` を解釈できず「代入式が無効」等で落ちるため（対象 repo は
  鉄則 4 のとおり既定に埋め込まない）。副作用は seam 関数に切り出し、`BOOCH_WIN_NORUN=1` で main を
  抑止して Pester から dot-source 検証する。
- `lib/*.ps1`: 汎用機構（winget / sync / cleanup / autoremove / download / doctor / go / rust /
  npm / textlint / github / codex / claude / font / openvpn / system ＋ 取り込み補助 `bootstrap`・
  help 用 `apidoc`）。利用側 dotfiles-win がエントリで dot-source する。**個人選択（何を入れるか）は
  持たない** — それは利用側の config。
- `bin/booch-win.ps1`: 補助 CLI（`help` / `version`）。`help` は `lib/apidoc.ps1` に委譲。
- `templates/`: 利用側 dotfiles-win の雛形（`scaffold`）。生成物に個人固有値を埋め込まず
  プレースホルダで示す。
- `VERSION`: SemVer 1 行（`version` と git タグ `v<...>` を一致させる）。

## 動作確認

```powershell
Invoke-Pester -Path ./tests -Output Detailed                 # ユニットテスト（Pester 5）
Invoke-ScriptAnalyzer -Path ./win.ps1 -Settings ./PSScriptAnalyzerSettings.psd1   # 対象ごとに lint
```

- ネットワーク / winget / gh / git を伴う処理は seam に切り出し、スタブで分岐を純粋に検証する。
- 実 winget・実認証・実 clone までの実地スモークは使い捨ての near-clean な Windows で行う
  （`tests/sandbox/manual-smoke.md`）。ホスト型 CI では不可能なのでそこを手動の正とする。

## ドキュメントの保守

API・構成・前提を変えたら **README.md も更新する**。使い方の正本は README、拡張ルールの正本は
本ファイル（重複させない）。
