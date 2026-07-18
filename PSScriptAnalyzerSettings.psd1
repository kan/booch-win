@{
    Severity = @('Error', 'Warning')

    # bootstrap スクリプト固有の事情で除外するルール:
    ExcludeRules = @(
        # ユーザー向け bootstrap は装飾付きの進捗表示が要るため Write-Host を許容する。
        'PSAvoidUsingWriteHost',
        # Install-/Update- 動詞だが -WhatIf/-Confirm を持たせる設計ではない（内部ヘルパー）。
        'PSUseShouldProcessForStateChangingFunctions',
        # win.ps1 は irm|iex で取得・評価される主経路を持つ。PS5.1 の irm は UTF-8 BOM を
        # 除去せず、先頭 BOM が <# コメントを壊して起動不能になるため win.ps1 は意図的に
        # BOM 無し。この検査は全ファイル一括なので除外する（lib/bin は dot-source される
        # ので BOM 付きのまま。BOM 規約の正本は CLAUDE.md 鉄則 2）。
        'PSUseBOMForUnicodeEncodedFile'
    )
}
