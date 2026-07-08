#requires -Version 5.1
# lib/apidoc.ps1 の抽出ロジックを検証する (Pester 5)。
# 表示関数 (Show-*) ではなく、ソースからヘッダ・要約・関数シグネチャを取り出す
# データ関数を対象にする。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $script:Root 'lib') 'apidoc.ps1')
    $script:CommonPath = Join-Path (Join-Path $script:Root 'lib') 'common.ps1'
}

Describe 'Get-BoochWinModuleHeader' {
    It '#Requires 行を含めない' {
        $header = Get-BoochWinModuleHeader -Path $script:CommonPath
        ($header | Where-Object { $_ -match '#Requires' }) | Should -BeNullOrEmpty
    }
    It 'コメントの # を外して返す' {
        $header = Get-BoochWinModuleHeader -Path $script:CommonPath
        ($header | Where-Object { $_ -match '^#' }) | Should -BeNullOrEmpty
    }
    It '最初の非空行にファイル名プレフィックスを含む' {
        $first = Get-BoochWinModuleHeader -Path $script:CommonPath |
            Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1
        $first | Should -Match 'common\.ps1:'
    }
}

Describe 'Get-BoochWinModuleSummary' {
    It 'lib/<name>.ps1: プレフィックスを外す' {
        $summary = Get-BoochWinModuleSummary -Path $script:CommonPath
        $summary | Should -Not -Match '\.ps1:'
        $summary | Should -Match '出力ヘルパー'
    }
}

Describe 'Get-BoochWinModuleFunctions' {
    BeforeAll {
        $script:Fns = Get-BoochWinModuleFunctions -Path $script:CommonPath
    }
    It 'トップレベル公開関数を列挙する' {
        ($script:Fns | Where-Object { $_ -like 'Write-Info(*' }) | Should -Not -BeNullOrEmpty
        ($script:Fns | Where-Object { $_ -like 'Test-Cmd(*' })   | Should -Not -BeNullOrEmpty
    }
    It '型制約付き引数を [type]$name で併記する' {
        ($script:Fns | Where-Object { $_ -eq 'Write-Info([string]$Msg)' }) | Should -Not -BeNullOrEmpty
    }
    It '構文エラーを含むファイルは部分抽出せず空を返す' {
        $broken = Join-Path $TestDrive 'broken.ps1'
        Set-Content -LiteralPath $broken -Value "function Good {`n}`nfunction Bad( {`n" -Encoding UTF8
        (Get-BoochWinModuleFunctions -Path $broken).Count | Should -Be 0
    }
    It '正常なファイルからは関数を抽出する' {
        (Get-BoochWinModuleFunctions -Path (Join-Path (Join-Path $script:Root 'lib') 'apidoc.ps1')).Count |
            Should -BeGreaterThan 0
    }
}

Describe 'Resolve-BoochWinModule' {
    It '存在するモジュールのパスを返す' {
        Resolve-BoochWinModule -Name 'winget' -Root $script:Root | Should -Match 'winget\.ps1$'
    }
    It '存在しないモジュールで $null を返す' {
        Resolve-BoochWinModule -Name 'no-such-module' -Root $script:Root | Should -BeNullOrEmpty
    }
}

Describe 'Get-BoochWinModuleList' {
    It 'lib/*.ps1 を列挙し winget/sync/common を含む' {
        $names = (Get-BoochWinModuleList -Root $script:Root).Name
        $names | Should -Contain 'winget'
        $names | Should -Contain 'sync'
        $names | Should -Contain 'common'
    }
    It '各要素が実在するパスを持つ' {
        foreach ($m in Get-BoochWinModuleList -Root $script:Root) {
            Test-Path -LiteralPath $m.Path | Should -BeTrue
        }
    }
}

Describe 'Show-BoochWinApiModule' {
    It '不明なモジュールで $false を返す' {
        Show-BoochWinApiModule -Name 'no-such-module' -Root $script:Root 6>$null | Should -BeFalse
    }
    It '既知のモジュールで $true を返す' {
        Show-BoochWinApiModule -Name 'winget' -Root $script:Root 6>$null | Should -BeTrue
    }
}
