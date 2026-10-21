#requires -Version 5.1
# lib/browser.ps1 を検証する (Pester 5)。COM とレジストリには触れず、seam と New-Object をモックする。
#
# 見たいのは次の 3 点。
# - on-demand API の状態の進み方 (更新なし / 更新あり → 導入完了 / エラー / 待ちきれない) を取り違えないこと
# - 表示の分け方 (最新 / 更新した / 再起動待ち / 失敗 / 未導入)
# - 失敗しても例外を外へ出さないこと

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')
    . (Join-Path $lib 'browser.ps1')

    # Update3Web の bundle の代わり。$States を 1 回の currentState 参照ごとに 1 つ進める
    # (最後の値に達したらそこに留まる)。呼ばれたメソッドを $Calls に記録する。
    function New-FakeBundle {
        param([object[]]$States, [int64]$ErrorCode = 0)
        $bundle = [pscustomobject]@{ States = $States; Index = 0; Calls = [System.Collections.Generic.List[string]]::new(); ErrorCode = $ErrorCode }
        foreach ($m in 'initialize', 'checkForUpdate', 'install', 'cancel') {
            $bundle | Add-Member -MemberType ScriptMethod -Name $m -Value ([scriptblock]::Create("`$this.Calls.Add('$m')"))
        }
        $bundle | Add-Member -MemberType ScriptMethod -Name createInstalledApp -Value { param($id) $this.Calls.Add("app:$id") }
        # appWeb(index) の index は 0 しか使わないので見ない
        $bundle | Add-Member -MemberType ScriptMethod -Name appWeb -Value {
            $v =$this.States[[Math]::Min($this.Index, $this.States.Count - 1)]
            $this.Index++
            [pscustomobject]@{ currentState = [pscustomobject]@{ stateValue = $v; errorCode = $this.ErrorCode } }
        }
        return $bundle
    }
}

Describe 'Get-BrowserSpec' {
    It 'Chrome と Edge の定義を返す' {
        (Get-BrowserSpec 'Chrome').Exe | Should -Be 'chrome.exe'
        (Get-BrowserSpec 'Edge').ProgId | Should -Be 'MicrosoftEdgeUpdate.Update3WebMachine'
        Get-BrowserName | Should -Be @('Chrome', 'Edge')
    }

    It '対応していない名前は throw する' {
        { Get-BrowserSpec 'Firefox' } | Should -Throw '*Firefox*'
    }
}

Describe 'Invoke-BrowserOnDemandUpdate' {
    BeforeEach {
        Mock Start-Sleep {}
        Mock New-Object {
            $u = [pscustomobject]@{ Bundle = $script:Bundle }
            $u | Add-Member -MemberType ScriptMethod -Name createAppBundleWeb -Value { $this.Bundle }
            $u
        } -ParameterFilter { $ComObject }
    }

    It '更新が無ければ no-update を返し、導入を始めない' {
        $script:Bundle = New-FakeBundle -States @(1, 3, 16)
        $r = Invoke-BrowserOnDemandUpdate -ProgId 'X.Update3WebMachine' -AppId '{APP}'
        $r.State | Should -Be 'no-update'
        $script:Bundle.Calls | Should -Be @('initialize', 'app:{APP}', 'checkForUpdate')
    }

    It '更新があれば導入し、導入完了で updated を返す' {
        $script:Bundle = New-FakeBundle -States @(3, 4, 7, 13, 14)
        $r = Invoke-BrowserOnDemandUpdate -ProgId 'X.Update3WebMachine' -AppId '{APP}'
        $r.State | Should -Be 'updated'
        $script:Bundle.Calls | Should -Contain 'install'
    }

    It 'エラーの状態なら error とエラーコードを返す (負の値も 8 桁で出す)' {
        $script:Bundle = New-FakeBundle -States @(3, 17) -ErrorCode -2147024891
        $r = Invoke-BrowserOnDemandUpdate -ProgId 'X.Update3WebMachine' -AppId '{APP}'
        $r.State | Should -Be 'error'
        $r.Detail | Should -Be 'error code 0x80070005'
    }

    It '導入の途中でエラーになったら error を返す' {
        $script:Bundle = New-FakeBundle -States @(4, 7, 17) -ErrorCode 1
        $r = Invoke-BrowserOnDemandUpdate -ProgId 'X.Update3WebMachine' -AppId '{APP}'
        $r.State | Should -Be 'error'
        $script:Bundle.Calls | Should -Contain 'install'
    }

    It '待ちきれなければ取り消して timeout を返す' {
        $script:Bundle = New-FakeBundle -States @(3)
        # 1 回目の Get-Date (期限の計算) より後は、期限を過ぎた時刻を返す
        $script:Now = Get-Date
        $script:Ticks = 0
        Mock Get-Date { $script:Ticks++; if ($script:Ticks -le 1) { $script:Now } else { $script:Now.AddHours(1) } }
        $r = Invoke-BrowserOnDemandUpdate -ProgId 'X.Update3WebMachine' -AppId '{APP}' -TimeoutSec 5
        $r.State | Should -Be 'timeout'
        $script:Bundle.Calls | Should -Contain 'cancel'
    }

    It '想定外の状態で止まったら、取り消さずに error を返す (時間切れと取り違えない)' {
        $script:Bundle = New-FakeBundle -States @(3, 11)
        $r = Invoke-BrowserOnDemandUpdate -ProgId 'X.Update3WebMachine' -AppId '{APP}' -TimeoutSec 5
        $r.State | Should -Be 'error'
        $r.Detail | Should -BeLike '*state 11*'
        $script:Bundle.Calls | Should -Not -Contain 'cancel'
    }

    It 'TimeoutSec が 0 なら期限を設けず、状態が進むまで待つ (--no-timeout)' {
        $script:Bundle = New-FakeBundle -States @(3, 3, 3, 3, 16)
        Mock Get-Date { [datetime]::MaxValue.AddDays(-1) }
        $r = Invoke-BrowserOnDemandUpdate -ProgId 'X.Update3WebMachine' -AppId '{APP}' -TimeoutSec 0
        $r.State | Should -Be 'no-update'
    }

    It '既定の待ち時間は Get-EffectiveTimeout を通す (--no-timeout なら無制限)' {
        Mock Get-EffectiveTimeout { 0 }
        Mock Get-Date { [datetime]::MaxValue.AddDays(-1) }
        $script:Bundle = New-FakeBundle -States @(3, 3, 16)
        (Invoke-BrowserOnDemandUpdate -ProgId 'X.Update3WebMachine' -AppId '{APP}').State | Should -Be 'no-update'
        Should -Invoke Get-EffectiveTimeout -ParameterFilter { $Default -eq 600 }
    }

    It 'COM を作れなければ例外を外へ出さず error を返す' {
        Mock New-Object { throw 'クラスが登録されていません' } -ParameterFilter { $ComObject }
        $r = Invoke-BrowserOnDemandUpdate -ProgId 'X.Update3WebMachine' -AppId '{APP}'
        $r.State | Should -Be 'error'
        $r.Detail | Should -BeLike '*登録されていません*'
    }
}

Describe 'Update-Browser' {
    BeforeEach {
        $script:Versions = @('155.0.1.0', '155.0.1.0')   # 呼ばれるたびに先頭から返す (前, 後)
        $script:VerIndex = 0
        Mock Get-BrowserInstalledVersion {
            $v = $script:Versions[[Math]::Min($script:VerIndex, $script:Versions.Count - 1)]
            $script:VerIndex++
            $v
        }
        Mock Get-BrowserRunningVersion { '155.0.1.0' }
        Mock Test-BrowserRelaunchPending { $false }
        Mock Invoke-BrowserOnDemandUpdate { [pscustomobject]@{ State = 'no-update'; Detail = '' } }
        Mock Write-Info {}
        Mock Write-Ok {}
        Mock Write-Warn {}
        Mock Write-Fail {}
    }

    It '最新なら up to date と出す' {
        Update-Browser -Name 'Chrome'
        Should -Invoke Invoke-BrowserOnDemandUpdate -Times 1 -Exactly -ParameterFilter { $ProgId -eq 'GoogleUpdate.Update3WebMachine' }
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -eq 'Chrome: 155.0.1.0 (up to date)' }
    }

    It '更新して再起動待ちでなければ、前後の版を出す' {
        $script:Versions = @('155.0.1.0', '156.0.1.2')
        Mock Invoke-BrowserOnDemandUpdate { [pscustomobject]@{ State = 'updated'; Detail = '' } }
        Update-Browser -Name 'Edge'
        Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Msg -eq 'Edge: 155.0.1.0 → 156.0.1.2' }
    }

    It '再起動待ちなら、起動中の版と導入済みの版を出して再起動を促す' {
        $script:Versions = @('155.0.1.0', '156.0.1.2')
        Mock Invoke-BrowserOnDemandUpdate { [pscustomobject]@{ State = 'updated'; Detail = '' } }
        Mock Test-BrowserRelaunchPending { $true }
        Update-Browser -Name 'Chrome'
        Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Msg -like 'Chrome: 155.0.1.0 → 156.0.1.2 *再起動*' }
        Should -Invoke Write-Ok -Times 0 -Exactly
    }

    It '前回の実行で導入済みのまま再起動していなければ、更新が無くても再起動を促す' {
        $script:Versions = @('156.0.1.2', '156.0.1.2')
        Mock Test-BrowserRelaunchPending { $true }
        Update-Browser -Name 'Chrome'
        Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Msg -like '*155.0.1.0 → 156.0.1.2*' }
    }

    It '未導入なら確認しない' {
        $script:Versions = @('')
        Update-Browser -Name 'Chrome'
        Should -Invoke Invoke-BrowserOnDemandUpdate -Times 0 -Exactly
        Should -Invoke Write-Info -Times 1 -Exactly
    }

    It '失敗と待ちきれないときは、それぞれ失敗と警告を出す' {
        Mock Invoke-BrowserOnDemandUpdate { [pscustomobject]@{ State = 'error'; Detail = 'error code 0x80070005' } }
        Update-Browser -Name 'Chrome'
        Should -Invoke Write-Fail -Times 1 -Exactly -ParameterFilter { $Msg -like '*0x80070005*' }
        Mock Invoke-BrowserOnDemandUpdate { [pscustomobject]@{ State = 'timeout'; Detail = '600 秒' } }
        Update-Browser -Name 'Chrome'
        Should -Invoke Write-Warn -Times 1 -Exactly
    }

    It 'Show-BrowserStatus: 未導入は SKIP、再起動待ちは WARN、それ以外は OK を出す' {
        Mock Write-Status {}
        $script:Versions = @('')
        Show-BrowserStatus -Name 'Chrome'
        Should -Invoke Write-Status -Times 1 -Exactly -ParameterFilter { $Label -eq 'chrome' -and $Status -eq 'SKIP' }
        $script:Versions = @('156.0.1.2'); $script:VerIndex = 0
        Mock Test-BrowserRelaunchPending { $true }
        Show-BrowserStatus -Name 'Chrome'
        Should -Invoke Write-Status -Times 1 -Exactly -ParameterFilter { $Status -eq 'WARN' -and $Detail -like '155.0.1.0 → 156.0.1.2*' }
        $script:VerIndex = 0
        Mock Test-BrowserRelaunchPending { $false }
        Show-BrowserStatus -Name 'Edge'
        Should -Invoke Write-Status -Times 1 -Exactly -ParameterFilter { $Label -eq 'edge' -and $Status -eq 'OK' -and $Detail -eq '156.0.1.2' }
    }

    It '対応していない名前は失敗を出し、例外を外へ出さない' {
        { Update-Browser -Name 'Firefox' } | Should -Not -Throw
        Should -Invoke Write-Fail -Times 1 -Exactly
        Should -Invoke Invoke-BrowserOnDemandUpdate -Times 0 -Exactly
    }
}
