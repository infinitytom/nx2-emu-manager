# EmuManager 启动器：先做语法检查，再运行主脚本；任何启动失败都会弹窗并写入 startup-error.log
$ErrorActionPreference = 'Stop'
$main = Join-Path $PSScriptRoot 'EmuManager.ps1'
$log  = Join-Path $PSScriptRoot 'startup-error.log'
function Show-Fatal([string]$title, [string]$text) {
    try { [IO.File]::WriteAllText($log, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "`r`n" + $title + "`r`n" + $text, (New-Object Text.UTF8Encoding($true))) } catch { }
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show($text + "`r`n`r`n（详情已写入 startup-error.log）", $title, 'OK', 'Error')
}
if (-not (Test-Path -LiteralPath $main)) { Show-Fatal 'EmuManager 启动失败' "找不到 $main"; exit 1 }
$tokens = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($main, [ref]$tokens, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    $msg = ($errs | Select-Object -First 8 | ForEach-Object { "第 $($_.Extent.StartLineNumber) 行：$($_.Message)`r`n    $($_.Extent.Text)" }) -join "`r`n"
    Show-Fatal 'EmuManager 语法错误' $msg
    exit 1
}
try { & $main }
catch {
    Show-Fatal 'EmuManager 运行出错' ($_.Exception.Message + "`r`n" + $_.InvocationInfo.PositionMessage + "`r`n" + $_.ScriptStackTrace)
    exit 1
}
