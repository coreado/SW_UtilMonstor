<#
.SYNOPSIS
  UtilMonster.exe 를 만든다 (Windows 에 기본 포함된 .NET Framework 컴파일러 사용, 별도 설치 불필요).
  아이콘(UtilMonster.ico)이 없으면 먼저 만든다.
  사용: .\tools\Build-Exe.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$ico = Join-Path $root 'UtilMonster.ico'
$exe = Join-Path $root 'UtilMonster.exe'
$src = Join-Path $PSScriptRoot 'Launcher.cs'

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe 를 찾을 수 없습니다: $csc" }

if (-not (Test-Path -LiteralPath $ico)) { & (Join-Path $PSScriptRoot 'MakeIcon.ps1') -Out $ico }

& $csc /nologo /target:winexe /optimize+ "/out:$exe" "/win32icon:$ico" /reference:System.Windows.Forms.dll /reference:System.dll $src
if ($LASTEXITCODE -ne 0) { throw "컴파일 실패 (코드 $LASTEXITCODE)" }
Write-Host "만들었습니다: $exe"
