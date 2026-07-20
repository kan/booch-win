# Changelog

このプロジェクトの主な変更を記録する。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。バージョンの正本は
ルートの `VERSION`（`booch-win version` と git タグ `v<...>` をこれに一致させる）。

## [Unreleased]

## [0.6.3] - 2026-07-20

### Added
- `Test-DirectoryInSync`（`lib/sync.ps1`）: ディレクトリ配下（再帰）のファイル一式が一致するかを
  相対パス集合と内容の両方で判定する。実体コピーで配ったもの（`Copy-Item -Recurse` で配備した
  スキル等）が配布元からずれていないかを診断するための判定。コピー方式は配布元が更新されても
  配備先が黙って古いまま残るため、これが無いと「配るのに、配った結果は見ない」状態になる。

## [0.6.2] - 2026-07-20

### Added
- `Show-ToolList`（`lib/doctor.ps1`）が任意の `Latest`（最新版を返す scriptblock）を受け取り、
  現在版と比較して注記を添えるようになった。`(update available: X)` /
  `(latest: unknown)` / `(latest: X)`。遅れていても MISSING にはしない（可視化が目的）。
  どのツールをどこと比較するかは消費側の config が持つ（機構と選択の分離。Linux の
  `booch_doctor_tool` と prefetch URL の分担と同じ）。
- `Get-VersionNumber` / `Get-VersionNote`（`lib/doctor.ps1`）: 版表記の正規化と注記の組み立て。
- `Get-NpmLatestVersion`（`lib/npm.ps1`）: npm レジストリの dist-tag latest。スコープ付きも可。
- `Get-GoModuleLatestVersion`（`lib/go.ps1`）: Go モジュールプロキシの最新 semver タグ。

### Fixed
- `Install-WingetPackages`（`lib/winget.ps1`）が upgrade の終了コードを捨てていたため、更新が
  失敗し続けても setup ログに何も出なかった（install の失敗は `Write-Fail` していたので非対称）。
  「適用できる更新が無い」（0x8A15002B）だけを成功扱いにし、それ以外の非 0 は警告として出す。
  判定は `Test-WingetUpgradeNoop` に切り出した。

## [0.6.1] - 2026-07-20

### Added
- `Update-ClaudeMarketplace`（`lib/claude.ps1`）: 登録済みの全 marketplace を最新化する
  （`claude plugin marketplace update`）。`Add-ClaudeMarketplace` は「未登録なら add」しか
  しないため、これが無いと marketplace の clone が追加時の版のまま古び、marketplace 側で
  更新されたプラグイン（スキル・コマンド）が何度 setup を回しても降ってこない。Linux 版 booch の
  `booch_claude_marketplace_update_all` と対になる。失敗は警告に留め、既存の clone のまま続行する。
- `Get-ClaudePluginVersion`（`lib/claude.ps1`）: 導入済みプラグインの版を `claude plugin list` から
  読む。`plugin@marketplace` の完全一致でブロックを特定するので、版行を持たないブロックで
  次のプラグインの版を誤って拾わない。

### Fixed
- `Enable-ClaudePlugin`（`lib/claude.ps1`）が導入済みプラグインに何もせず、初回 install 時点の版で
  凍結していた。導入済みなら `claude plugin update` をかけ、版が変わったときだけ updated と報告する
  （Linux 版 booch の `booch_claude_plugin_ensure` と対）。update 失敗は致命でないので握る。

## [0.6.0] - 2026-07-19

### Added
- `lib/keyboard.ps1`: キーボード remap（Scancode Map）と入力方式（TSF）の設定。
  `Get-ScancodeMapBytes` / `Test-ScancodeMapCurrent` / `Set-ScancodeMap` /
  `Test-InputMethodCurrent` / `Set-InputMethod`。どのキーを入れ替えるか・どの入力方式にするかは
  引数で受け取り、機構だけを持つ。既定入力方式の override も張る（張らないと言語リスト先頭が
  既定になり、目的の入力方式が既定にならない）。
- `lib/wsl.ps1`: WSL2 とディストロの導入。`Get-WslDistros`（UTF-16 出力の null を除去）/
  `Install-WslDistro`（`already` / `needs-admin` / `installed` / `needs-restart` を返し、
  次の手順の案内は消費側に任せる）。
- `Copy-FilesIfChanged`（`lib/sync.ps1`）: repo 側が正本のファイル群を配置先へ一方向配置する
  （内容が違うものだけコピーし、コピーしたファイル名を返す）。`$SyncPairs` の双方向同期と違い、
  公開鍵や同梱データのような「配るだけ」の用途向け。
- `Write-InfoLines`（`lib/common.ps1`）: 複数行テキスト（外部コマンドの出力など）を空行を除いて
  `Write-Info` で 1 行ずつ出す。

## [0.5.1] - 2026-07-19

### Added
- `Update-SessionPath`（`lib/winget.ps1`）: winget 導入後にレジストリ（Machine + User）から
  実行中プロセスの PATH を再合成する。winget は導入ツールのパスを現プロセス PATH に反映しない
  ため、同じ run の後半で直前に導入したツール（node/go/rustup/uv 等）が見つからず失敗するのを
  防ぐ（新規環境を 1 回の setup で完走させるための要）。
- `CLAUDE.md`: booch-win 自体の開発ルール（個人 dotfiles を持ち込まない等）。

### Changed
- `win.ps1`: 設定を環境変数（`BOOCH_WIN_REPO` 必須 / `BOOCH_WIN_DIR` / `BOOCH_WIN_NORUN`）で
  受ける方式へ。param ブロック / `[CmdletBinding()]` を廃し、UTF-8 BOM も外した。個人リポジトリ
  `kan/dotfiles` を既定に埋め込まず、対象 repo は利用者が指定する。
- `win.ps1`: clone を `--recurse-submodules` にし、clone/pull 後に `git submodule update` を
  実行する（委譲先 dotfiles-win.ps1 が booch-win submodule を要するため）。

### Fixed
- `irm | iex`（PS5.1）で `win.ps1` が起動できない問題。`Invoke-RestMethod` 評価では版によって
  先頭の param / `[CmdletBinding()]`、および `irm` が除去しない UTF-8 BOM が「予期しない属性」
  「代入式が無効」等のパースエラーになる。param 廃止・環境変数化・BOM 除去で解消（実機 PS5.1 で確認）。
- `$ErrorActionPreference='Stop'` のまま native コマンド（gh/winget/git）が stderr に書くと
  `NativeCommandError` で terminating になり `$LASTEXITCODE` を見る前に停止する問題を
  `Invoke-Native` で回避（gh 未ログイン時の `gh auth status` で bootstrap が止まっていた）。

## [0.5.0] - 2026-07-15

### Added
- `Invoke-BoochWinWorktreePrune`（`lib/cleanup.ps1`）: 指定した各 git repo で `git worktree prune`
  を回し、実体が消えた worktree の登録メタだけを掃除する（冪等・安全。実在 worktree は消さない）。
  git 不在・非 git ディレクトリはスキップ。どの repo を対象にするかは消費側が渡す。Linux 側 booch
  の `booch_cleanup_worktree_prune` と対称（消費側 dotfiles-win.ps1 の自己完結実装を booch-win へ寄せた）。

## [0.4.0] - 2026-07-15

### Added
- `Invoke-BoochWinAutoremove`（`lib/autoremove.ps1`）: 宣言（消費側の `$ClaudePlugins` /
  `$ClaudeMarketplaces` / `$CodexSkillsFromMarketplace`）から外れた Claude プラグイン /
  marketplace / marketplace clone 残渣 / codex skill を洗い出し、一覧提示 → 確認 → 削除する
  手動オーケストレーション。`-DryRun` / `-AssumeYes` に対応。plan 算出（`Get-BoochWinAutoremovePlan`）
  と適用（`Invoke-BoochWinAutoremoveOne`）はシームとして分離し、消費側 doctor が plan だけを
  引いて可視化できる。MCP / `$SyncPairs` は Windows では宣言が空 / 実体コピーで残骸を安全に
  判別できないため対象外。Linux 側 `dotfiles autoremove` と対称。

## [0.3.0] - 2026-07-08

### Added
- `Invoke-BoochWinCleanup`（`lib/cleanup.ps1`）: 一時ファイル / npm・go キャッシュ / Tauri
  target / WSL vhdx 最適化の掃除を Mode（light|full）と opt-in フラグ（-CleanTauri /
  -CompactVhdx）で行う。消費側（dotfiles-win）の `Invoke-Cleanup` はモード検証とタイトルを
  出してこれへ委譲する薄いラッパーになる。

## [0.2.0] - 2026-07-08

### Added
- `booch-win scaffold <kind> -Path <dir> [-Force]`（`lib/scaffold.ps1` + `templates/`）で
  booch-win を使う dotfiles-win リポジトリの最小雛形を生成する。生成物は冪等（既存は上書き
  しない）で、submodule 追加などの手順は生成される README に案内する。
- `Invoke-BoochWinSync`（`lib/sync.ps1`）: SyncPair を順に判定し差分を diff 表示して対話
  選択（r/e/s）で反映する同期オーケストレーション。消費側（dotfiles-win）の `Invoke-Sync`
  はこれを呼ぶ薄いラッパーになる（表示・対話の挙動は従来と同一）。

## [0.1.0] - 2026-07-08

最初のリリース。

### Added
- ワンライナー bootstrap `win.ps1`（素の Windows から private dotfiles を入れて
  `dotfiles-win setup` が走る状態までを 1 コマンドで持っていく）。
- dotfiles-win 汎用ライブラリ `lib/*.ps1`（`common` / `sync` / `winget` / `doctor` /
  `download` / `github` / `go` / `rust` / `npm` / `textlint` / `codex` / `claude` /
  `font` / `openvpn` / `system`）。個人設定に依存しない PowerShell 実装。
- 補助 CLI `bin/booch-win.ps1`（`help` / `help <module>` / `version`）と、ソースから
  ヘッダ・公開関数を抽出する `lib/apidoc.ps1`。
- 消費側取り込み用の `lib/bootstrap.ps1`（`Resolve-BoochWinRoot` / `Get-BoochWinLibFile`）。
- Tier1 CI（Pester モックテスト + PSScriptAnalyzer + 構文 parse、`windows-latest`）と
  Tier2 手動スモーク手順（Windows Sandbox）。

[Unreleased]: https://github.com/kan/booch-win/compare/v0.6.3...HEAD
[0.6.3]: https://github.com/kan/booch-win/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/kan/booch-win/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/kan/booch-win/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/kan/booch-win/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/kan/booch-win/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/kan/booch-win/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/kan/booch-win/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/kan/booch-win/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kan/booch-win/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kan/booch-win/releases/tag/v0.1.0
