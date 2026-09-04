# Changelog

このプロジェクトの主な変更を記録する。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。バージョンの正本は
ルートの `VERSION`（`booch-win version` と git タグ `v<...>` をこれに一致させる）。

## [Unreleased]

## [0.23.1] - 2026-09-04

### Fixed
- `Show-ClaudeMarketplaces` が参照先 (`Repo`) しか見ておらず、**表示名 (`Name`) が宣言と
  食い違っている状態を緑で通していた**。marketplace の表示名は repo パスではなく
  `marketplace.json` の `name` が決めるので、両者がずれると `Add-ClaudeMarketplace`
  （`Name` で判定）が毎回 add をやり直し、`Enable-ClaudePlugin` の `plugin@<Name>` も解決
  できない。一番気付きにくい壊れ方なので、専用の警告（登録名を併記）を出すようにした。
- marketplace 更新の失敗で claude が無言のとき（kill された / 出力を吐かない）、
  `update failed ()` と空の括弧になり、理由を出す前より情報が減っていた。理由が取れない
  ときは従来の案内（「既存の clone のまま続行します。ネットワーク / 認証を確認してください」）
  へフォールバックする。
- `Get-ClaudeFailureReason` の `IndexOf('✘ ')` が culture-sensitive なオーバーロード
  （PS5.1 は CurrentCulture、PS7 は ICU 比較）だったのを `[StringComparison]::Ordinal` に
  した。意図は部分文字列探索なので序数比較が正確で速い。

### Tests
- 全体更新の失敗テストで `Get-ClaudeMarketplaceName` が 2 件返すようにし、片方だけ失敗させる
  形にした。壊れたものだけを名指しすることに加え、ループが途中で `break` / `return` せず
  全件回ることも担保する。

## [0.23.0] - 2026-09-04

### Added
- `Get-BoochWinDisplayWidth` / `Format-BoochWinPadRight`（`lib/common.ps1`）: 端末に表示した
  ときの桁数で測る / 右詰めする。East Asian Wide・Fullwidth（漢字・かな・全角記号）を 2 桁、
  サロゲートペア（絵文字）を 2 桁として数える。

### Fixed
- `Write-Status` の桁揃えが `.PadRight`（.NET の**文字数**）だったため、日本語を含むラベルの
  行だけ `[OK]` が右へずれていた（全角 1 文字は 1 文字と数えられるのに端末では 2 桁を占める）。
  表示幅で埋めるようにした。`Get-SyncPairLabelWidth`（`lib/sync.ps1`）の幅算出も同じ尺度に
  揃えた。これで doctor のラベルに日本語を使ってよくなる。
- `Write-Status` の既定 `LabelWidth` を 28 → 33 にした。0.22.0 で足した
  `    mkt:claude-plugins-official`（31 桁）が 28 を超え、その行だけ `[OK]` がラベルに密着して
  いた。ラベルを足すときの計算をコメントに残してある。
- `Update-ClaudeMarketplace` が `$true` / `$false` を返していたため、戻り値を代入せずに呼ぶ
  利用側（`dotfiles-win` の Claude 節）のコンソールへ `True` / `False` が素の行として漏れて
  いた。PowerShell は代入されなかった戻り値を出力ストリームへ流すため。**値を返さない**形に
  戻し、回帰ガードのテストを足した。
- `Show-ClaudeMarketplaces` の `-Marketplaces` が `Mandatory` で、宣言を空にすると
  パラメータバインドの終了エラーで doctor ごと落ちていた。既定 `@()` にし、`Show-ClaudePlugins`
  と同じく「出すものが無ければ黙る」に揃えた。

### Tests
- `Get-BoochWinRegisteredMarketplace`（`lib/autoremove.ps1`）が `Get-ClaudeMarketplaceName` へ
  委譲していることの検証を追加。plan 側のテストはこの関数を丸ごと Mock するため、委譲先の
  綴りを間違えても parse も Pester も通り、実機で初めて `CommandNotFoundException` になる。

## [0.22.0] - 2026-09-04

### Added
- `Show-ClaudeMarketplaces`（`lib/claude.ps1`）: 宣言した marketplace が登録されているかを
  doctor へ列挙する。**プラグイン行では代替できない** — marketplace 側が消えても既に入って
  いるプラグインは enabled のまま古い版で居座るので、`Show-ClaudePlugins` だけ見ていると
  凍結に気付けない。判定は `Source: GitHub (owner/name)` の固定文字列照合で、参照先の
  付け替えにも気付ける。
- `Get-ClaudeMarketplaceName`（`lib/claude.ps1`）: 登録済み marketplace 名を配列で返す。
  `lib/autoremove.ps1` の `Get-BoochWinRegisteredMarketplace` にあった実装をこちらへ移し
  （CLI 出力書式の解析は claude 側の関心）、旧名は薄いラッパーとして残した。
- `Get-ClaudeFailureReason`（`lib/claude.ps1`）: claude の出力から警告に載せる 1 行の理由を
  作る。進捗と結果を同じ行に吐く書式なので、失敗マーカー（`✘`）以降を本文とみなす。

### Changed
- `Update-ClaudeMarketplace` が `claude plugin marketplace update` の出力を `Out-Null` で
  捨てていたのをやめ、失敗理由を警告に載せるようにした。claude は「1 marketplace could not
  be refreshed: \<name\>」のように**どれが壊れたか**を出力に書くので、捨てると
  「update failed」としか言えなかった。加えて全体更新が失敗したときは登録済みの名前ごとに
  引き直し、壊れているものだけを名指しする（正常時は全体更新 1 回のまま）。`-Name` で
  単体更新もできる。Linux 版 booch 1.12.0 の marketplace ヘルパーと対称。

## [0.21.0] - 2026-09-03

### Added
- `Show-ToolList`（`lib/doctor.ps1`）のツール要素に `Optional` と `WingetId`。`Optional = $true`
  は「入っていなくてもよい」宣言で、未導入なら `MISSING`（赤）ではなく `SKIP`（未導入 (任意)）に
  し missing 集計にも数えない（`Install-WingetPackages` の同名キーと対になる。一部の機械にしか
  入れないものを doctor へ載せられるようにするため）。未導入のときは `Latest` を引かない。
- `Show-ToolList` に `-WingetIds`。`Get-WingetInstalledIds` の結果を渡すと、ツールの `WingetId`
  との厳密一致でも導入判定する。PATH に実行ファイルを出さないもの（開発者シェルの中にしか
  出ない MSVC の `link.exe` 等）を「導入済みでも未検出」にしないため。判定は
  `Test-ToolInstalled`（公開）に切り出した。ID 集合が空（未取得・取得失敗）でその ID でしか
  見つけられないツールは、`MISSING` ではなく `SKIP`（判定不能）にする — 取得できなかったことを
  「未導入」へ丸めると、winget が詰まった回だけ doctor が exit 1 になるため
  （`Get-WingetInstallState` の `'Unknown'` を丸めないのと同じ扱い）。
- `Show-WingetUntracked`（`lib/winget.ps1`）に `-InstalledIds`。取得済みの ID 集合を渡せば
  `winget export` を再実行しない（doctor が `Show-ToolList` と 1 回の取得を共有できる）。
  空配列は「取得を試みて失敗した」であって未指定ではないので、取り直さず従来の SKIP 行にする
  （取り直すと、winget が詰まっている回にだけ読み取り上限をもう一度払うことになる）。

## [0.20.0] - 2026-09-02

### Added
- `Install-WingetPackages`（`lib/winget.ps1`）のパッケージ要素に `Optional`。`$true` なら
  未導入のときは install せず、導入済みのときだけ upgrade する。全マシンへ配りたくない
  重いもの（ビルドツール・SDK 等）を「入っている環境だけ最新に保つ」ために使う。宣言に
  載るので `Show-WingetUntracked` の追跡外一覧にも出なくなる。省略時は従来どおり未導入
  なら install する。

### Fixed
- `tests/autoremove.Tests.ps1` の「走査後は呼び出し元の `CLAUDE_CONFIG_DIR` へ戻す」が、
  呼び出し元では未設定という前提で書かれていた。`CLAUDE_CONFIG_DIR` を設定して起動する端末
  （アカウントを切り替えるラッパー等）では、正しく元へ戻しているのに失敗していた。呼び出し元
  が未設定・設定済みの両方について「元の値へ戻る」ことを見るようにした（機構側の変更は無し）。

## [0.19.0] - 2026-08-31

### Added
- `Show-ClaudePlugins`（`lib/claude.ps1`）に `-Indent`。プラグイン行のラベル前置きを呼び出し側
  から指定できるようにした（既定は従来どおり 2 スペース）。

### Fixed
- config dir ごとの行を挟んで `Show-ClaudePlugins` を呼ぶと、プラグイン名が dir 行と同じ深さに
  並んでどの dir のものか読めなかった。インデントが 2 スペース固定だったため。消費側は
  `-Indent '    '` を渡してもう 1 段下げられる。

## [0.18.0] - 2026-08-31

### Added
- `lib/claude.ps1`: Claude Code の config dir（= アカウント）を扱う 3 関数。
  `Get-ClaudeConfigPath`（`CLAUDE_CONFIG_DIR` の値 → 実際の dir。空文字は既定 dir）/
  `Set-ClaudeConfigDir`（被せる・空文字で未設定へ戻す）/ `Invoke-WithClaudeConfigDir`
  （scriptblock の実行中だけ被せ、終了後に呼び出し元の値へ戻す）。**既定の dir を
  `CLAUDE_CONFIG_DIR` に明示設定してはいけない**（だから既定は空文字で表す）——
  グローバル設定 `.claude.json` の置き場が「環境変数があればその配下、無ければ
  `$HOME\.claude.json`」なので、明示すると別ファイルへ切り替わり user スコープ MCP・
  プロジェクト履歴・信頼状態が失われたように見える。
- `lib/autoremove.ps1`: `Get-BoochWinAutoremovePlan` / `Invoke-BoochWinAutoremove` に
  `-ClaudeConfigDirs`、`Invoke-BoochWinAutoremoveOne` に `-ConfigDir` を追加。plugin /
  marketplace / mktclone は config dir ごとに別管理なので、渡された dir を 1 つずつ走査する
  （既定は空文字 1 件 = 既定 dir だけで、従来と同じ挙動）。plan 要素に `ConfigDir` が増え、
  複数 dir を走査したときは一覧にどの dir の名残かを併記する。config dir に依らない
  codexskill は 1 回だけ判定し `ConfigDir` は `$null`。mktclone の安全弁 Root も config dir
  から導出するので、plan と apply が同じ根拠になる。

### Fixed
- `lib/claude.ps1` / `lib/autoremove.ps1`: claude CLI をベア名 `& claude ...` で呼ぶのをやめ、
  `Get-ClaudeCommand`（`Get-Command -CommandType Application`）が返す実体経由に統一した。
  呼び出し側のスコープに `claude` という**関数やエイリアス**があると PowerShell のコマンド
  解決はそちらを優先するため、本ライブラリの CLI 呼び出しが丸ごと乗っ取られていた（対話
  プロファイルで claude をラップし、そのセッションから setup を走らせると再現する。PATH の
  ベア名解決は `.ps1` を PATHEXT の `.cmd` より先に選ぶので、シム側の `-NoProfile` では
  防げない）。Linux 版 booch が固定バイナリ `$BOOCH_CLAUDE_BIN` を直叩きしているのと同じ
  方針に揃えた。
- 同じ理由で、claude の導入有無の判定を `Test-Cmd 'claude'` から `Test-ClaudeInstalled`
  （実体だけを見る）へ変更した。`Test-Cmd` は種別を絞らない `Get-Command` なので、同名の
  関数があると**未導入のマシンでも「導入済み」と誤判定**し、`Install-ClaudeCode` が更新側へ
  分岐して npm での導入フォールバックが動かなかった。

## [0.17.0] - 2026-08-28

### Added
- `lib/winget.ps1`: winget の `settings.json` をキー単位で冪等に更新する
  `Update-WingetSettings`（純粋なマージ部は `Merge-WingetSettingsJson`、置き場の解決は
  `Get-WingetSettingsPath`）。ユーザーが書いた他キーを保ったまま指定キーだけを反映し、
  変更が無ければ書かない。MSIX 版（App Installer）と非パッケージ版のどちらの置き場にも
  対応する。用途の一例は `network.downloader` の固定で、既定の Delivery
  Optimization が 0 バイトのまま滞留すると winget が自前ダウンローダへ落ちるまで待たされる
  （実測で 63 MB の取得に 13 分、うち実ダウンロードは 3 秒）。コメント付き（JSONC）や
  壊れた JSON は書き換えずに投げる（PS7 の `ConvertFrom-Json` は JSONC を読めてしまい、
  そのまま書き戻すとコメントが落ちるため、実装側で明示的に弾いて版による差を消している）。

## [0.16.0] - 2026-08-25

### Added
- `lib/git.ps1`: 複数 git repo を一括で ff-only pull する `Invoke-BoochWinGitPullRepos`
  （と 1 repo 版 `Update-BoochWinGitRepo`）。Linux 側 booch の `booch_git_pull_repos` /
  `booch_git_pull_ff_clean` に対応する Windows 版で、消費側は「基準ディレクトリ・repo 名・
  許可ブランチ」だけを渡す。`.git` が無い対象は黙って除外し（clone していないマシンで
  警告を出さないため）、許可ブランチ外・作業ツリーが dirty な repo には触らない。
  更新有無の判定は pull 前後の HEAD sha 比較で行い、`Already up to date` の文言照合に
  頼らない（日本語 locale で翻訳されるため）。実 git を叩く箇所は seam
  （`Get-BoochWinGitBranch` / `Test-BoochWinGitDirty` / `Get-BoochWinGitHead` /
  `Invoke-BoochWinGitFfPull`）に切り出してある。

## [0.15.0] - 2026-08-19

### Fixed
- `Invoke-WingetRead` が winget の終了コードを取り落とし、**未導入のパッケージでも
  `Get-WingetInstallState` が `'Installed'` を返していた**のを修正した。PS5.1 の
  `Start-Process -PassThru` は、リダイレクト（`-RedirectStandardOutput` /
  `-RedirectStandardError`）を併用すると返す Process がプロセスハンドルを保持せず、子の終了後に
  `.ExitCode` が `$null` になる。それを `[int]` へキャストしていたので 0、つまり「exit 0 =
  導入済み」に化けていた。起動直後に `.Handle` を評価してハンドルを開き、それでも取れなければ
  `$null` のまま返す（0 へ丸めない → 呼び出し側の `'Unknown'` 経路に乗る）。
  読み取り系にタイムアウトを入れてリダイレクトを併用した 0.13.0 からの回帰で、既に全部
  導入済みの機では誤判定と正解が一致するため表面化せず、**利用側が `$WingetPackages` に
  新しいパッケージを足したときだけ**「install されず upgrade が走り、
  `NO_APPLICATIONS_FOUND`（0x8A150014）で毎回失敗して永久に入らない」という形で出ていた。

### Added
- `Invoke-WingetRead` に `-FilePath`（既定 `winget.exe`）。終了コードを取れるかどうかが
  `Start-Process` の使い方そのものに依存し、`Invoke-WingetRead` を mock した契約テストでは
  捕まらないため、実プロセスで回帰を突けるようにする（`tests/winget.Tests.ps1` が `cmd.exe` で
  終了コード・タイムアウト・起動失敗を検証する）。

## [0.14.0] - 2026-08-15

### Changed
- `Install-ClaudeCode` は、`claude update` が失敗したときの npm フォールバックを
  **claude.exe が実行中ならスキップして警告する**ようになった。npm はグローバル更新の前に
  既存パッケージを一時ディレクトリへ退避コピーするため、実行中の claude.exe を掴んだまま
  では `EBUSY: resource busy or locked, copyfile ...\claude.exe` で必ず落ちる。Claude Code の
  セッションから setup を回すと毎回この生の npm エラーが出るが、成功する見込みが無い実行
  なので、警告 1 行に畳んで claude 終了後の再実行へ委ねる。

### Added
- `Get-ClaudeProcess`: 実行中の Claude Code プロセスを列挙する（未起動なら空配列）。

## [0.13.0] - 2026-08-14

### Changed
- **破壊的変更**: `Test-WingetInstalled` を廃止し、3 値を返す `Get-WingetInstallState`
  （`'Installed'` / `'NotInstalled'` / `'Unknown'`）へ置き換えた。真偽値では「判定できなかった」を
  表せず、`$false` へ丸めれば install が、`$true` へ丸めれば upgrade が走る——どちらもソース参照で
  同じく止まりうるため、丸めずに第 3 の状態として返す。
- 副作用の無い読み取り系 winget 呼び出し（`winget list` / `winget export`）に上限を設けた
  （既定 60 秒。エントリ側の `$Script:WingetReadTimeoutSec` で変更、`--no-timeout` で無制限）。
  winget は起動のたびにソースインデックス（`cdn.winget.microsoft.com`）を参照しうるため、そこが
  詰まると応答が返らず、`Install-WingetPackages` はパッケージ数ぶん待ちが伸びていた。
  `install` / `upgrade` には**手を入れない** — インストーラーの実行中に kill するとパッケージが
  中途半端な状態で残り、上限で得られるものより失うものが大きい。
- `Install-WingetPackages` は導入状態が `'Unknown'` のパッケージを警告付きでスキップする。
  実行が 1 回飛ぶだけで、冪等なので次回の実行が拾う。
- `Get-WingetInstalledIds` はタイムアウト・起動失敗のときも既存契約どおり空配列を返す
  （`Show-WingetUntracked` は従来どおり SKIP 表示になる）。
- `Set-InputMethod` は、TIP の実体が登録されていなければ警告するようになった。設定が既に
  正しい場合（従来は早期 return していた経路）でも見る — そここそが「設定は正しいのに
  入力できない」状態そのものだから。修復はしない（消費側の担当）。

### Added
- TSF TIP の**登録の実体**を判定する API を `lib/keyboard.ps1` に追加した。既存の
  `Test-InputMethodCurrent` は言語一覧と既定入力、つまり入力方式の「設定」しか見ておらず、
  設定が指す TIP の実体が消えても言語一覧には TIP 文字列が残るため true のままになる。
  IME 本体を使用中に upgrade すると実際に起きる状態（インストーラーが COM 登録を次回ログオンへ
  先送りする／新版を入れた後に旧版のアンインストーラーが同じ CLSID の登録を消す）で、
  **設定は正しいのに日本語入力が丸ごと死ぬ**のに doctor は「正常」と表示していた。
  - `Get-InputMethodTipId`: TIP 文字列 `<言語 ID 16進4桁>:{CLSID}{PROFILE}` を分解する。
    判定に要る情報はすべてここから導けるので、消費側は CLSID を二重管理しなくてよい。
  - `Get-InputMethodTipRegistryPath`: 64bit / 32bit（`WOW6432Node`）の `InProcServer32` と
    `CTF\TIP\...\LanguageProfile`（言語 ID を 8 桁ゼロ埋めした `0x00000411` 形式）のパス。
  - `Get-InputMethodTipState`: 登録の実体を読む。「どちらのビューを要求するか」は
    `$Dll64` / `$Dll32` で消費側が渡す（TIP DLL の在り処は IME 実装ごとに違い、片方しか
    無い機で誤検知しないため）。
  - `Get-InputMethodTipProblem`: State だけで決まる純粋関数。噛み合わない理由の一覧を返す。
  - `Test-InputMethodTipInstalled` / `Test-InputMethodTipMissing` /
    `Test-InputMethodTipRegistered`。
  - **修復（`regsvr32` での再登録）は持たない** — TIP DLL の場所が IME 実装ごとに違うため、
    booch-win は判定まで、入れ直しは消費側に残す。
- `Invoke-WingetRead`: 読み取り系 winget を上限付きで実行し `@{ TimedOut; ExitCode }` を返す seam。
  出力はコンソールへ出さず捨てる（表示が要らない経路なので、`Invoke-Winget` のようにコンソール
  所有権を渡す必要が無い。むしろ渡すと中断できなくなる）。
- `Get-WingetReadTimeout`: 読み取り系の実効タイムアウトを解決する（既定 60 秒 →
  `$Script:WingetReadTimeoutSec` → `Get-EffectiveTimeout`）。
- `tests/winget.Tests.ps1` に `Get-WingetReadTimeout` / `Get-WingetInstallState` /
  `Get-WingetInstalledIds` / `Install-WingetPackages` の分岐検証を追加（`Invoke-WingetRead` を
  mock して純粋に検証する）。
- `tests/keyboard.Tests.ps1` に TIP 登録判定の検証を追加（TIP 文字列の分解・レジストリパス・
  不整合の判定・弱い判定、`Set-InputMethod` の警告）。

### Fixed
- `Install-WingetPackages` のヘッダコメントが `Get-WingetInstalledIds` の上に紛れていたため、
  `booch-win help winget` が両者の説明を取り違えていたのを直した。

## [0.12.0] - 2026-08-03

### Changed
- `Install-Textlint`（`lib/textlint.ps1`）が、`$SrcDir` に `package-lock.json` が無いときは
  `npm install` に続けて `npm update` も走らせるようにした。`$DestDir` に残る lockfile は初回
  install の副産物だが、`npm install` は**それが `package.json` のレンジを満たす限り古い版を
  保持する**ため、レンジ内に新版が出ても再実行で永久に前進しなかった（textlint が `^15.7.1` の
  まま 15.8.0 へ上がらず、doctor が毎回「更新あり」を出し続けた）。`$SrcDir` に lockfile が
  **ある**ときは意図された版固定とみなし従来どおり install のみ。レンジ外（メジャー跨ぎ）は
  動かないので、`package.json` の手 bump が要る点は変わらない。booch の
  `booch_npm_local_install`（1.10.0）と同じ判断で、Linux/Windows の版追従を揃える。

### Added
- `tests/textlint.Tests.ps1`: `Install-Textlint` の版追従分岐（src の lockfile 有無で
  install のみ / install + update）を検証する。npm は関数でシャドウして引数だけ記録する。

## [0.11.0] - 2026-07-29

### Fixed
- `Invoke-BoochWinCompactWsl` が **非昇格でも WSL を停止してから失敗していた**。縮小には
  管理者権限が要る（`Optimize-VHD` / `diskpart` のどちらの経路でも）が、権限確認は
  `Optimize-BoochWinVhdx` の中＝ WSL 停止より後にしかなかった。消費側が昇格の面倒を見る経路
  （`compact-wsl` 相当のサブコマンド）では事前に弾けていたが、`Invoke-BoochWinCleanup
  -CompactVhdx` のように機構を直接呼ぶ経路では停止だけが先に起きる。0.10.0 の sparse 判定と
  同じ理由で、**停止の前に**弾くようにした。
- `Optimize-BoochWinVhdx` の diskpart フォールバックで、`compact vdisk` が失敗すると
  `detach vdisk` に到達せず vhdx が read-only アタッチのまま残りえた（diskpart はスクリプト中の
  1 行が失敗するとそれ以降を実行しない）。失敗時に後始末のデタッチを試みる。

### Added
- `Dismount-BoochWinVhdx`: diskpart でアタッチしたままの vhdx をデタッチする best-effort
  ヘルパー（compact 失敗時の後始末に使う）。

### Security
- `Optimize-BoochWinVhdx` の diskpart フォールバックで、パスに改行・引用符が含まれる場合を
  拒否するようにした。diskpart はスクリプトファイル経由でパスを受け取るため、そのまま埋め込むと
  昇格した `diskpart.exe` に意図しない追加コマンドを読ませうる。呼び出し元の `Get-WslVhdxPath`
  が `Test-Path` で実在確認しており到達しにくい経路だが、機構側でも塞ぐ。

## [0.10.0] - 2026-07-29

### Fixed
- `Invoke-BoochWinCompactWsl` が **sparse な vhdx に対しても WSL を停止してから compact を
  試み、必ず失敗していた**。VHD API は sparse ファイルを開けない（実機のエラー:
  `Virtual hard disk files must be uncompressed and unencrypted and must not be sparse`）ので、
  `Optimize-VHD` も `diskpart` も成功しえない。稼働中のコンテナ・シェルを無駄に落とすだけの
  動作だったため、判定を先に行い、sparse なら **WSL を停止せずに** 状態を報告して終わる。
  - sparse と compact は排他。sparse な vhdx はゲストの TRIM（WSL 内の `fstrim`）で実占有が
    減るので、そもそも compact は不要（実測: `fstrim` 込みの掃除で C: の空きが 10GB → 72GB）。
  - 非 sparse の vhdx だけが compact の対象。縮小後は sparse 化を案内する。
- `Optimize-BoochWinVhdx` が sparse 判定を権限確認より先に行うようにした。昇格しても結果は
  変わらないので、無駄な UAC プロンプトを出さない。

### Added
- `Test-FileSparse -Path <file>`（`lib/system.ps1`）: NTFS の sparse 属性判定。WSL の vhdx では
  「自動解放されるが compact 不可（sparse）」と「compact が要る（非 sparse）」の分岐点になる。

## [0.9.0] - 2026-07-29

### Fixed
- `Invoke-BoochWinCompactWsl` が `wsl --manage <Distro> --compact` を呼んでいたが、**wsl.exe に
  そのオプションは存在しない**（`--manage` が持つのは `--move` / `--set-sparse` /
  `--set-default-user` だけ。WSL 2.7.11 で確認）。常に `Wsl/E_INVALIDARG` で失敗し、しかも
  エラー文言が「WSL が古い場合は wsl --update」だったため、最新の WSL でも直らない誤った
  案内を出し続けていた。縮小は `Optimize-BoochWinVhdx`（Hyper-V の `Optimize-VHD`、無ければ
  `diskpart` の `compact vdisk`）で行う。
- 縮小の前後表示が論理サイズ（`Length`）だった。sparse な vhdx では論理サイズはほとんど
  減らず（実測で論理 213GB / 実占有 151GB）、解放量が 0 に見えてしまう。実占有で報告する。

### Added
- `Optimize-BoochWinVhdx -Path <vhdx>`（`lib/cleanup.ps1`）: vhdx の実縮小。`Optimize-VHD` を
  優先し、無ければ `diskpart` にフォールバックする。どちらも管理者権限とデタッチ済み
  （`wsl --shutdown` 済み）が前提なので、非昇格なら実行せず `$false` を返す。
- `Get-FileAllocatedSize -Path <file>`（`lib/system.ps1`）: sparse ファイルの実占有バイト数
  （`GetCompressedFileSize`）。ドライブの空きに効くのはこちらなので、vhdx の表示・解放量の
  計算はすべてこの値を使う。

### Changed
- `Show-WslVhdxSize`（`lib/doctor.ps1`）が「実占有（論理）」の形で両方を出すようにした。
  論理サイズだけだと、fstrim で解放済みでも巨大なまま見える。

## [0.8.0] - 2026-07-29

### Added
- `Invoke-BoochWinCompactWsl`（`lib/cleanup.ps1`）: WSL を停止して ext4.vhdx を縮小する
  （`wsl --shutdown` → 未設定なら `--set-sparse` → `--compact`）。従来は
  `Invoke-BoochWinCleanup -CompactVhdx` の中に埋まっていて cleanup 経由でしか呼べなかったが、
  WSL 内で消した分を Windows 側の空きへ反映する操作は単独で実行したい（掃除とは別軸の作業で、
  実行のたびに WSL を落とす）。消費側は専用サブコマンドから直接呼べる。
- `Stop-BoochWinWsl`（`lib/cleanup.ps1`）: `wsl --shutdown` + 解放待ちの seam。テストで実際に
  WSL を落とさずに compact の分岐を検証するために切り出した。
- `Show-DiskFree -Drive C -WarnGB 20 [-Hint ...]`（`lib/doctor.ps1`）: ドライブの空き容量行。
  閾値未満で WARN を出し、真偽値を返す（消費側の missing/warn 集計に載せられる）。
  Linux 側 booch の `booch_doctor_disk` と対称。
- `Show-WslVhdxSize`（`lib/doctor.ps1`）: 各 WSL ディストロの ext4.vhdx 実サイズを列挙する。
  WSL 内で削除しても vhdx は自動では縮まないため、ドライブの空きと乖離する値を可視化する。

### Changed
- `Invoke-BoochWinCleanup -CompactVhdx` は `Invoke-BoochWinCompactWsl` へ委譲する（振る舞いは同じ）。

## [0.7.0] - 2026-07-25

### Added
- `Get-ClaudeVersion`（`lib/claude.ps1`）: Claude Code 本体の版を返す（未導入・取得失敗は空文字）。
  `claude --version` の "2.1.220 (Claude Code)" から版だけを取り出し、プラグインの版表示と粒度を揃える。

### Changed
- `Install-ClaudeCode`（`lib/claude.ps1`）が本体の版を導入の前後で取り直し、上がったときは
  `Claude Code: updated (old -> new)`、変わらなければ `already installed (版)` と報告するようにした。
  従来は版に触れず `already installed` としか出さないため、更新されても何が上がったか読めず、
  本体だけ `Enable-ClaudePlugin`（`updated (old -> new)`）と非対称だった。

## [0.6.6] - 2026-07-20

### Added
- `Remove-OutdatedFontFile`（`lib/font.ps1`）: このファミリ用に置いた ttf のうち、指定バージョンの
  配置名でないものを消す。別名配置方式では旧版・旧命名の実体が宙に浮くため（実測 1 ファミリ 124MB）。
  導入直後だけでなく「既に最新」の回にも呼べる — 導入時だけの掃除だと、そのとき使用中で消せな
  かった分が次のリリースまで残り続けるため。掴まれていて消せないものは次回に回す。

## [0.6.5] - 2026-07-20

### Fixed
- `Install-Font`（`lib/font.ps1`）の更新が実際には成立しなかった。同名 ttf を上書きしようと
  するため、動作中のアプリ（setup を走らせているターミナル自身を含む）が掴んでいて必ず失敗する
  （実測で 16/16 ファイルが使用中）。配置名にリリースタグを埋めて別ファイルとして置き、HKCU の
  表示名キーは同じまま値を新しいパスへ差し替える方式に変えた。表示名が変わらないのでフォント
  一覧に重複は出ず、ロックも回避できる。
- 旧版・旧命名のファイルは配置後に掃除する（レジストリが新しいパスを指すので実体は宙に浮く。
  掴まれていて消せない分は次回に回す）。対象は `$TtfPattern` に一致するものだけ。

### Added
- `Get-FontDestFileName`（`lib/font.ps1`）: 配置名の組み立て（`<base>_<tag><ext>`）。

## [0.6.4] - 2026-07-20

### Added
- `Get-FontInstalledVersion` / `Get-FontVersionStampPath`（`lib/font.ps1`）: フォントを
  どのリリースから入れたかを記録・参照する。ttf 内部のバージョンは配布元のタグと一致せず、
  ファイル名も版を含まないため、記録が無いと更新の要否を判断できず初回導入時の版で凍結する。

### Changed
- `Install-Font`（`lib/font.ps1`）は導入済みでも呼べる更新経路になった（同名 ttf を上書き）。
  成功したらリリースタグを記録する。更新時に動作中のアプリが ttf を掴んでいて置き換えられない
  ファイルは名指しで報告し、1 つでも失敗したらタグを記録せず次回やり直せるようにする
  （失敗を記録すると中途半端な状態で「最新」と誤判定して固定されてしまう）。

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

[Unreleased]: https://github.com/kan/booch-win/compare/v0.23.1...HEAD
[0.23.1]: https://github.com/kan/booch-win/compare/v0.23.0...v0.23.1
[0.23.0]: https://github.com/kan/booch-win/compare/v0.22.0...v0.23.0
[0.22.0]: https://github.com/kan/booch-win/compare/v0.21.0...v0.22.0
[0.21.0]: https://github.com/kan/booch-win/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/kan/booch-win/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/kan/booch-win/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/kan/booch-win/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/kan/booch-win/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/kan/booch-win/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/kan/booch-win/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/kan/booch-win/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/kan/booch-win/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/kan/booch-win/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/kan/booch-win/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/kan/booch-win/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/kan/booch-win/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/kan/booch-win/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/kan/booch-win/compare/v0.6.6...v0.7.0
[0.6.6]: https://github.com/kan/booch-win/compare/v0.6.5...v0.6.6
[0.6.5]: https://github.com/kan/booch-win/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/kan/booch-win/compare/v0.6.3...v0.6.4
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
