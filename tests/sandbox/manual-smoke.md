# Tier2: Windows Sandbox 手動スモーク

`win.ps1` の**実環境スモーク**（実 winget・実認証・実 clone まで）を、使い捨ての
near-clean な Windows で行う手順。ホスト型 CI では winget 不在・対話認証・UAC 昇格のため
不可能なので、ここを手動の正とする（背景は kan/dotfiles#7）。

> 閉じれば全部消えるので、何度でもまっさらからやり直せる。

## 0. 前提（ホスト側、初回のみ）

Windows 11 Pro/Enterprise で **Windows Sandbox 機能**を有効化する（管理者 PowerShell）:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

有効化後に再起動。以降は `booch-win-smoke.wsb` をダブルクリックで Sandbox が起動する。

## 1. Sandbox 起動

`tests/sandbox/booch-win-smoke.wsb` をダブルクリック。ネットワーク有効・PowerShell が開いた
状態で立ち上がる。

> ローカルの未 push 版 `win.ps1` を試したいときは `.wsb` の `MappedFolders` を有効化し、
> Sandbox 内で `C:\booch-win\win.ps1` を直接実行する（下の「ローカル版を試す」参照）。

## 2. winget を入れる（Sandbox の弱点）

**Windows Sandbox には既定で winget(App Installer) が無い。** `win.ps1` は winget 前提なので、
実 winget 経路まで試すには先に入れる。Sandbox 内 PowerShell で:

```powershell
$ErrorActionPreference = 'Stop'; $t = "$env:TEMP\wg"; New-Item -ItemType Directory -Force $t | Out-Null
Invoke-WebRequest https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx -OutFile "$t\vclibs.appx"
Invoke-WebRequest https://aka.ms/getwinget -OutFile "$t\winget.msixbundle"
Add-AppxPackage "$t\vclibs.appx"
Add-AppxPackage "$t\winget.msixbundle"
winget --version   # 出れば成功
```

> `Add-AppxPackage` が `Microsoft.UI.Xaml` 依存エラーを出す場合は、対応する UI.Xaml の
> appx を入れてから winget.msixbundle を再実行する（NuGet `Microsoft.UI.Xaml` から取得）。
> ここが Sandbox 最大の手間。winget 経路を省いて**フォールバック動作だけ**確認したい場合は
> 本ステップを飛ばし、`win.ps1` が「App Installer 不在」で親切に止まるかを見る（#7 の TODO）。

## 3. ワンライナーを実行（公開版）

```powershell
irm https://raw.githubusercontent.com/kan/booch-win/main/win.ps1 | iex
```

## 4. 各ステージの確認ポイント（win.ps1 の流れに対応）

| # | 期待 | 見るところ |
|---|---|---|
| 1 | `winget available` | step2 を実施していれば OK。未実施なら親切な throw が出るか |
| 2 | `git` / `gh` を winget 導入 | 既に無い前提。`--silent`。**Git.Git で UAC が出るか**を観察（要記録） |
| 3 | PATH 再解決 | 直後に `git --version` / `gh --version` が通るか（"not found" にならないか） |
| 4 | GitHub 認証 | `gh auth login --web` がブラウザ/コードを出すか。**Sandbox 内ブラウザで完遂できるか**を確認 |
| 5 | clone or pull | `kan/dotfiles` が `$HOME\dotfiles` に入るか。再実行で pull になり壊れないか（冪等） |
| 6 | 委譲 | `dotfiles-win.ps1 setup` が起動するか。`powershell -ExecutionPolicy Bypass -File` 経由で実行できるか |

## 5. 記録すべき結果（#7 へフィードバック）

- [ ] `gh auth login --web` は対話セッションで完遂できたか（要修正なら `--with-token` 検討）
- [ ] `winget install --silent` で UAC が出たか（出るなら README/コメントの「昇格は本体へ委譲」を再考）
- [ ] PATH 再解決後に `git`/`gh` が即使えたか
- [ ] 2 回目実行が冪等だったか（install skip / pull）
- [ ] App Installer 不在時の throw メッセージは十分親切か（TODO(#7) フォールバックの要否）

## ローカル版を試す（任意）

`.wsb` の `MappedFolders` を有効化して HostFolder を自分の clone パスにすると、未 push の
`win.ps1` を Sandbox 内で直接実行できる:

```powershell
& C:\booch-win\win.ps1            # 既定パラメータ
& C:\booch-win\win.ps1 -Dir C:\dot -Repo kan/dotfiles
```

## 後始末

Sandbox ウィンドウを閉じるだけ。状態は一切ホストに残らない。
