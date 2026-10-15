#requires -Version 5.1
# lib/system.ps1 のプロセス系譜の列挙を検証する (Pester 5)。Get-CimInstance をモックし、
# プロセス一覧を 1 回だけ取ってメモリ上で親をたどることを確認する。

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $lib = Join-Path $script:Root 'lib'
    . (Join-Path $lib 'common.ps1')
    . (Join-Path $lib 'system.ps1')

    function New-TestProcess {
        param([int]$Id, [int]$Parent, [string]$Name)
        [pscustomobject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name }
    }
}

Describe 'Get-CurrentProcessAncestor' {
    It '近い順に祖先をたどり、プロセス一覧は 1 回だけ取る' {
        Mock Get-CimInstance {
            New-TestProcess $PID 200 'pwsh.exe'
            New-TestProcess 200 300 'bash.exe'
            New-TestProcess 300 0 'wsl.exe'
            New-TestProcess 999 1 'other.exe'
        }
        $a = Get-CurrentProcessAncestor
        $a.ProcessId | Should -Be @(200, 300)
        $a.Name | Should -Be @('bash.exe', 'wsl.exe')
        Should -Invoke Get-CimInstance -Times 1 -Exactly
    }

    It '終了済みの親は名前を空にして、そこで止まる' {
        Mock Get-CimInstance { New-TestProcess $PID 200 'pwsh.exe' }
        $a = @(Get-CurrentProcessAncestor)
        $a.Count | Should -Be 1
        $a[0].ProcessId | Should -Be 200
        $a[0].Name | Should -Be ''
    }

    It '系譜が循環しても上限で止まる' {
        Mock Get-CimInstance {
            New-TestProcess $PID 200 'pwsh.exe'
            New-TestProcess 200 300 'a.exe'
            New-TestProcess 300 200 'b.exe'
        }
        @(Get-CurrentProcessAncestor).Count | Should -Be 32
    }
}

Describe 'Get-CurrentProcessAncestorId' {
    It '祖先の PID を近い順に返す' {
        Mock Get-CurrentProcessAncestor { @([pscustomobject]@{ ProcessId = 200; Name = 'a' }, [pscustomobject]@{ ProcessId = 300; Name = '' }) }
        Get-CurrentProcessAncestorId | Should -Be @(200, 300)
    }
}
