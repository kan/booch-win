# Changelog

このプロジェクトの主な変更を記録する。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。バージョンの正本は
ルートの `VERSION`（`booch-win version` と git タグ `v<...>` をこれに一致させる）。

## [Unreleased]

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

[Unreleased]: https://github.com/kan/booch-win/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/kan/booch-win/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kan/booch-win/releases/tag/v0.1.0
