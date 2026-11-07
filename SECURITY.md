# セキュリティポリシー

## 脆弱性の報告

booch-win に脆弱性を見つけたら、公開の Issue には書かず、GitHub の [Private vulnerability reporting](https://github.com/kan/booch-win/security/advisories/new) から報告してください。報告の内容は、修正を公開するまでメンテナーにだけ見えます。

報告には次の内容を書いてください。

- 脆弱性の内容
- 再現の手順
- 想定される影響（読み書きできるデータ、必要な権限など）

受け取った報告は、できるだけ早く確認して返信します。

## 対象

対象は、このリポジトリのコード（`main` ブランチの最新）と、ワンライナー bootstrap（`win.ps1`）が取得して実行する処理です。修正は最新の版にだけ当てます。

次のものは、それぞれの報告先へお願いします。

- winget や、導入する各ツールの配布物そのものの問題: それぞれの配布元
- Linux 版の問題: [kan/booch](https://github.com/kan/booch/security/policy)
