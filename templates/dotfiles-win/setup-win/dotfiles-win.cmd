@echo off
rem dotfiles-win.cmd: PowerShell / cmd から拡張子なしで dotfiles-win を呼ぶシム。
rem 同ディレクトリの dotfiles-win.ps1 へ委譲する。
rem
rem 引数は %* で一括展開せず個別に取り出して再クオートしてから渡す。%* は cmd に
rem 再パースされ & | > 等のメタ文字を含む引数が追加コマンドとして実行される恐れが
rem あるため。遅延展開 (!args!) の値はコマンド演算子として解釈されない。
setlocal EnableDelayedExpansion
set "args="
:collect
if "%~1"=="" goto run
if defined args (set args=!args! "%~1") else (set args="%~1")
shift
goto collect
:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dotfiles-win.ps1" !args!
