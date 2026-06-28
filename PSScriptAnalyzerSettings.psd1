@{
    Severity = @('Error', 'Warning')

    # bootstrap スクリプト固有の事情で除外するルール:
    ExcludeRules = @(
        # ユーザー向け bootstrap は装飾付きの進捗表示が要るため Write-Host を許容する。
        'PSAvoidUsingWriteHost',
        # Install-/Update- 動詞だが -WhatIf/-Confirm を持たせる設計ではない（内部ヘルパー）。
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
