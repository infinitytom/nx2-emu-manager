# EmuManager - Eden / Eglantine 多版本管理器
# https://github.com/infinitytom/eden-version-manager
# 双击 EmuManager.bat 启动。仅依赖 Windows 自带的 PowerShell 5.1 + .NET Framework (WPF)。
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:AppVersion = '2.0.0'

# ================================================================ 路径与持久化
$script:AppRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DataRoot   = Join-Path $AppRoot 'data'
$script:ConfigPath = Join-Path $DataRoot 'config.json'
$script:DbPath     = Join-Path $DataRoot 'db.json'
$script:RunsDir    = Join-Path $DataRoot 'runs'
$script:BackupRoot = Join-Path $DataRoot 'backups'
$script:RoomDir    = Join-Path $DataRoot 'room'
foreach ($d in @($DataRoot, $RunsDir, $BackupRoot, $RoomDir)) {
    if (-not [IO.Directory]::Exists($d)) { [void][IO.Directory]::CreateDirectory($d) }
}

function ConvertTo-HT($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-HT $p.Value }
        return $h
    }
    if (($o -is [System.Collections.IEnumerable]) -and -not ($o -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($x in $o) { [void]$list.Add((ConvertTo-HT $x)) }
        return ,$list
    }
    return $o
}
function Read-Json($path) {
    if ([IO.File]::Exists($path)) {
        try {
            $txt = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if ($txt.Trim()) { return (ConvertTo-HT ($txt | ConvertFrom-Json)) }
        } catch { }
    }
    return @{}
}
function Write-Json($path, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 12
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}
function Ensure-Key($h, $k, $v) { if (-not $h.ContainsKey($k) -or $null -eq $h[$k]) { $h[$k] = $v } }

$script:Drive = [IO.Path]::GetPathRoot($AppRoot)
$script:Cfg = Read-Json $ConfigPath
Ensure-Key $Cfg 'EmuRoots'      @($Drive)
Ensure-Key $Cfg 'GameRoots'     @($Drive)
Ensure-Key $Cfg 'VersionsDir'   (Join-Path $Drive 'EmuVersions')
Ensure-Key $Cfg 'EmuScanDepth'  3
Ensure-Key $Cfg 'GameScanDepth' 5
Write-Json $ConfigPath $Cfg

$script:Db = Read-Json $DbPath
Ensure-Key $Db 'emus' @{}
Ensure-Key $Db 'games' @{}
Ensure-Key $Db 'compat' @{}
Ensure-Key $Db 'profiles' @{}
Ensure-Key $Db 'room' @{}
Ensure-Key $Db 'runs' (New-Object System.Collections.ArrayList)
if (-not ($Db.runs -is [System.Collections.ArrayList])) {
    $tmp = New-Object System.Collections.ArrayList; foreach ($x in $Db.runs) { [void]$tmp.Add($x) }; $Db.runs = $tmp
}
function Save-Db { Write-Json $DbPath $script:Db }

$script:Statuses = @('未测试', '完美', '可玩', '卡顿/掉帧', '画面错误', '偶发崩溃', '必崩/卡死', '无法启动')
$script:StatusHex = @{
    '未测试' = '#3A4150'; '完美' = '#238636'; '可玩' = '#2EA043'; '卡顿/掉帧' = '#9E6A03'
    '画面错误' = '#B08800'; '偶发崩溃' = '#C9510C'; '必崩/卡死' = '#DA3633'; '无法启动' = '#8B1A1A'
}
$script:KnownTitles = @{ '040074A01BF12000' = '咚奇刚 蕉力全开' }
$script:ExitNames = @{
    'C0000005' = '访问冲突'; 'C0000409' = '栈缓冲溢出/abort'; 'C00000FD' = '栈溢出'
    'E06D7363' = 'C++ 异常'; '80000003' = '断点'; 'C0000374' = '堆损坏'; 'C000001D' = '非法指令'
    'C0000142' = 'DLL 初始化失败'; 'C0000135' = '缺少 DLL'; 'C000007B' = '映像格式错误'
}

# ================================================================ 通用工具
function Get-SubDirs([string]$path) {
    try { return ,[IO.Directory]::GetDirectories($path) } catch { return ,@() }
}
function Safe-Name([string]$s) {
    if (-not $s) { return '_' }
    $bad = [IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) { if ($bad -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) } }
    return $sb.ToString().Trim()
}
function Format-Size([int64]$b) {
    if ($b -lt 0) { return '' }
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return "$b B"
}
function Get-PathSize([string]$p) {
    if ([IO.File]::Exists($p)) { return (New-Object IO.FileInfo $p).Length }
    if ([IO.Directory]::Exists($p)) {
        $sum = [int64]0
        try { foreach ($f in [IO.Directory]::EnumerateFiles($p, '*', [IO.SearchOption]::AllDirectories)) { $sum += (New-Object IO.FileInfo $f).Length } } catch { }
        return $sum
    }
    return [int64]-1
}
function Format-Duration([int]$sec) {
    $ts = [TimeSpan]::FromSeconds($sec)
    if ($ts.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds) }
    return ('{0}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}
function Format-ExitCode($c) {
    if ($null -eq $c -or "$c" -eq '') { return '?' }
    $v = [int64]$c
    if ($v -eq 0) { return '0 (正常)' }
    if ($v -gt [int32]::MaxValue) { $u = [uint32]$v } else { $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$v), 0) }
    $hex = $u.ToString('X8')
    $n = $script:ExitNames[$hex]
    if ($n) { return "0x$hex $n" }
    return "0x$hex"
}
function Open-InExplorer([string]$p) {
    if ([IO.File]::Exists($p)) { Start-Process explorer.exe -ArgumentList ('/select,"' + $p + '"'); return }
    $q = $p
    while ($q -and -not [IO.Directory]::Exists($q)) { $q = [IO.Path]::GetDirectoryName($q) }
    if ($q) {
        Start-Process explorer.exe -ArgumentList ('"' + $q + '"')
        if ($q -ne $p) { Set-Status "目标不存在，已打开最近的上级目录：$q" }
    }
}
function Msg([string]$text, [string]$icon = 'Information') {
    if ($script:win -and $script:win.IsVisible) { [void][System.Windows.MessageBox]::Show($script:win, $text, 'EmuManager', 'OK', $icon) }
    else { [void][System.Windows.MessageBox]::Show($text, 'EmuManager', 'OK', $icon) }
}
function Confirm([string]$text) {
    if ($script:win -and $script:win.IsVisible) { $r = [System.Windows.MessageBox]::Show($script:win, $text, 'EmuManager', 'YesNo', 'Question') }
    else { $r = [System.Windows.MessageBox]::Show($text, 'EmuManager', 'YesNo', 'Question') }
    return ($r -eq 'Yes')
}
function Show-Err($e) {
    $line = ''
    try { $line = " (第 $($e.InvocationInfo.ScriptLineNumber) 行)" } catch { }
    Msg ("出错了$line：`n" + $e.Exception.Message) 'Error'
}
function Safe([scriptblock]$sb) { try { & $sb } catch { Show-Err $_ } }
$script:BrushCache = @{}
function To-Brush([string]$hex) {
    if (-not $script:BrushCache.ContainsKey($hex)) {
        $b = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex); $b.Freeze()
        $script:BrushCache[$hex] = $b
    }
    return $script:BrushCache[$hex]
}

# ================================================================ 模拟器扫描
$script:EmuExeNames  = @('eglantine.exe', 'eden.exe', 'citron.exe', 'sudachi.exe', 'suyu.exe', 'torzu.exe', 'yuzu.exe')
$script:CliExeNames  = @('eden-cli.exe', 'eglantine-cli.exe', 'eden-cmd.exe', 'yuzu-cmd.exe', 'citron-cmd.exe', 'suyu-cmd.exe', 'sudachi-cmd.exe')
$script:RoomExeNames = @('eden-room.exe', 'eglantine-room.exe', 'yuzu-room.exe', 'citron-room.exe', 'suyu-room.exe', 'sudachi-room.exe')
$script:SkipDirs = @('$RECYCLE.BIN', 'System Volume Information', 'romfs', 'exefs', '.git', 'node_modules', 'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData')

function Test-EmuDir([string]$p) {
    foreach ($n in ($script:EmuExeNames + $script:CliExeNames)) { if ([IO.File]::Exists((Join-Path $p $n))) { return $true } }
    return $false
}
function Get-AppDataName([string]$exeName) {
    $e = $exeName.ToLower()
    if ($e.StartsWith('yuzu') -or $e.StartsWith('torzu')) { return 'yuzu' }
    foreach ($n in @('citron', 'sudachi', 'suyu')) { if ($e.StartsWith($n)) { return $n } }
    return 'eden'
}
function Get-EmuInfo([string]$dir) {
    $gui = $null; $cli = $null; $room = $null
    foreach ($n in $script:EmuExeNames)  { $f = Join-Path $dir $n; if ([IO.File]::Exists($f)) { $gui = $f; break } }
    foreach ($n in $script:CliExeNames)  { $f = Join-Path $dir $n; if ([IO.File]::Exists($f)) { $cli = $f; break } }
    foreach ($n in $script:RoomExeNames) { $f = Join-Path $dir $n; if ([IO.File]::Exists($f)) { $room = $f; break } }
    $main = if ($gui) { $gui } else { $cli }
    $version = ''; $branch = ''; $commit = ''
    $info = ''
    foreach ($vf in @('VERSION.txt', 'BUILD-INFO.txt')) {
        $f = Join-Path $dir $vf
        if ([IO.File]::Exists($f)) { $info += [IO.File]::ReadAllText($f) + "`n" }
    }
    if ($info) {
        $first = @($info -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1
        if ($first) { $version = $first.Trim() }
        $m = [regex]::Match($info, '(?i)release\s*[:=]\s*(\S+)'); if ($m.Success) { $version = $version + ' ' + $m.Groups[1].Value }
        $m = [regex]::Match($info, '(?i)\bbranch\s*[:=]?\s*([\w\.\-/]+)'); if ($m.Success) { $branch = $m.Groups[1].Value }
    }
    $src = Join-Path $dir 'EMUMGR-SOURCE.txt'
    if ([IO.File]::Exists($src)) { $info += [IO.File]::ReadAllText($src) }
    $m = [regex]::Match($info, '(?i)\bcommit\s*[:=]?\s*([0-9a-f]{7,40})'); if ($m.Success) { $commit = $m.Groups[1].Value }
    if (-not $commit) {
        $zip = Get-ChildItem -LiteralPath $dir -Filter *.zip -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($zip) { $m = [regex]::Match($zip.Name, '([0-9a-f]{12,40})'); if ($m.Success) { $commit = $m.Groups[1].Value } }
    }
    if (-not $version) {
        try { $fvi = [Diagnostics.FileVersionInfo]::GetVersionInfo($main); if ($fvi.ProductVersion) { $version = $fvi.ProductVersion } } catch { }
    }
    $portable = [IO.Directory]::Exists((Join-Path $dir 'user'))
    $dataDir = if ($portable) { Join-Path $dir 'user' } else { Join-Path $env:APPDATA (Get-AppDataName ([IO.Path]::GetFileName($main))) }
    return [pscustomobject]@{
        Dir = $dir; Key = $dir.TrimEnd('\').ToLower(); Name = [IO.Path]::GetFileName($dir.TrimEnd('\'))
        Gui = $gui; Cli = $cli; Room = $room; Exe = $main; Version = $version; Branch = $branch; Commit = $commit
        BuildDate = [IO.File]::GetLastWriteTime($main); Portable = $portable; DataDir = $dataDir
    }
}
function Scan-Emus {
    $seen = @{}
    $result = New-Object System.Collections.ArrayList
    $roots = @($script:Cfg.EmuRoots) + @($script:Cfg.VersionsDir)
    foreach ($root in $roots) {
        if (-not $root -or -not [IO.Directory]::Exists($root)) { continue }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($root, 0))
        while ($queue.Count -gt 0) {
            $it = $queue.Dequeue(); $p = $it[0]; $depth = $it[1]
            if (Test-EmuDir $p) {
                $k = $p.TrimEnd('\').ToLower()
                if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; try { [void]$result.Add((Get-EmuInfo $p)) } catch { } }
                continue
            }
            if ($depth -ge [int]$script:Cfg.EmuScanDepth) { continue }
            foreach ($s in (Get-SubDirs $p)) {
                $n = [IO.Path]::GetFileName($s)
                if ($script:SkipDirs -contains $n) { continue }
                if ($s.StartsWith($script:DataRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $queue.Enqueue(@($s, ($depth + 1)))
            }
        }
    }
    return ,@($result | Sort-Object BuildDate -Descending)
}

# ================================================================ 游戏扫描
function Get-NpdmTitleId([string]$npdm) {
    try {
        $b = [IO.File]::ReadAllBytes($npdm)
        $aci = [int][BitConverter]::ToUInt32($b, 0x70)
        if ([Text.Encoding]::ASCII.GetString($b, $aci, 4) -ne 'ACI0') { return $null }
        return ([BitConverter]::ToUInt64($b, $aci + 0x10)).ToString('X16')
    } catch { return $null }
}
function Get-GameNameFromPath([string]$path) {
    $q = $path
    while ($q) {
        $n = [IO.Path]::GetFileName($q.TrimEnd('\'))
        if (-not $n) { break }
        if (($n -notmatch '^(base|updates?|patch(es)?|dlc|exefs|romfs|game|games)$') -and ($n -notmatch '^\d+$') -and ($n -notmatch '^[0-9A-Fa-f]{16}$')) { return $n }
        $q = [IO.Path]::GetDirectoryName($q)
    }
    return $path
}
function Add-GameContent($found, [string]$tid, [string]$path, [string]$type) {
    $kind = 'base'; $baseTid = $tid; $label = '基础'
    if ($type -eq 'file' -and $tid -notlike 'FILE:*') {
        $v = [Convert]::ToUInt64($tid, 16)
        $low = $v % 4096
        if ($low -eq 2048) { $kind = 'update'; $label = '更新'; $baseTid = $tid.Substring(0, 13) + '000' }
        elseif ($low -ne 0) { $kind = 'dlc'; $label = 'DLC'; $baseTid = ([UInt64]($v - 4096)).ToString('X16').Substring(0, 13) + '000' }
    }
    if ($type -eq 'dir') {
        $leaf = [IO.Path]::GetFileName($path)
        $parent = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path))
        if (($parent -match '^(updates?|patch(es)?)$') -or ($leaf -match '^\d+$')) {
            $kind = 'update'; $label = "更新 $leaf"
            if ($leaf -match '^\d+$') { $label = '更新 v' + [int64][math]::Floor([int64]$leaf / 65536) + " ($leaf)" }
        }
    }
    if (-not $found.ContainsKey($baseTid)) {
        $name = if ($type -eq 'file') { ([IO.Path]::GetFileNameWithoutExtension($path) -replace '\[[^\]]*\]', '').Trim() } else { Get-GameNameFromPath $path }
        $found[$baseTid] = [pscustomobject]@{ TitleId = $baseTid; FolderName = $name; Contents = (New-Object System.Collections.ArrayList); Dir = '' }
    }
    $g = $found[$baseTid]
    if ($kind -eq 'base' -and -not $g.Dir) { $g.Dir = if ($type -eq 'dir') { $path } else { [IO.Path]::GetDirectoryName($path) } }
    $launch = if ($type -eq 'dir') { Join-Path $path 'exefs\main' } else { $path }
    [void]$g.Contents.Add([pscustomobject]@{ Kind = $kind; Label = $label; Path = $path; Launch = $launch; Type = $type })
}
function Scan-Games {
    $found = @{}
    $skip = $script:SkipDirs + @('nand', 'shader', 'load', 'sdmc', 'dump', 'plugins', 'platforms', 'imageformats', 'styles', 'tls', 'iconengines', 'generic', 'networkinformation', 'LICENSES')
    foreach ($root in @($script:Cfg.GameRoots)) {
        if (-not $root -or -not [IO.Directory]::Exists($root)) { continue }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($root, 0))
        while ($queue.Count -gt 0) {
            $it = $queue.Dequeue(); $p = $it[0]; $depth = $it[1]
            $npdm = Join-Path $p 'exefs\main.npdm'
            if ([IO.File]::Exists($npdm)) {
                $tid = Get-NpdmTitleId $npdm
                if ($tid) { Add-GameContent $found $tid $p 'dir' }
                continue
            }
            $files = @(); try { $files = [IO.Directory]::GetFiles($p) } catch { }
            foreach ($f in $files) {
                $ext = [IO.Path]::GetExtension($f).ToLower()
                if (@('.nsp', '.xci', '.nsz', '.xcz') -contains $ext) {
                    $m = [regex]::Match([IO.Path]::GetFileName($f), '([0-9A-Fa-f]{16})')
                    $tid = if ($m.Success) { $m.Groups[1].Value.ToUpper() } else { 'FILE:' + $f }
                    Add-GameContent $found $tid $f 'file'
                }
            }
            if ($depth -ge [int]$script:Cfg.GameScanDepth) { continue }
            foreach ($s in (Get-SubDirs $p)) {
                $n = [IO.Path]::GetFileName($s)
                if ($skip -contains $n) { continue }
                if ($s.StartsWith($script:DataRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $queue.Enqueue(@($s, ($depth + 1)))
            }
        }
    }
    foreach ($g in $found.Values) {
        $sorted = @($g.Contents | Sort-Object @{ Expression = { switch ($_.Kind) { 'base' { 0 } 'update' { 1 } default { 2 } } } }, @{ Expression = { $_.Path }; Descending = $true })
        $g.Contents.Clear(); foreach ($c in $sorted) { [void]$g.Contents.Add($c) }
    }
    return ,@($found.Values | Sort-Object FolderName)
}

# ================================================================ 显示名称 / 兼容性
function Emu-Display($emu) {
    $e = $script:Db.emus[$emu.Key]
    if ($e -and $e.alias) { return $e.alias }
    return $emu.Name
}
function Game-Display($game) {
    $g = $script:Db.games[$game.TitleId]
    if ($g -and $g.alias) { return $g.alias }
    if ($script:KnownTitles.ContainsKey($game.TitleId)) { return $script:KnownTitles[$game.TitleId] }
    return $game.FolderName
}
function Compat-Key($emu, $game) { return ($emu.Key + '|' + $game.TitleId) }
function Get-Compat($emu, $game) {
    $k = Compat-Key $emu $game
    if (-not $script:Db.compat.ContainsKey($k)) { $script:Db.compat[$k] = @{ status = '未测试'; note = ''; lastRun = ''; lastExit = ''; lastSeconds = 0 } }
    return $script:Db.compat[$k]
}

# ================================================================ 数据位置
function Get-GameLocations($emu, $game) {
    $d = $emu.DataDir; $tid = $game.TitleId
    $L = New-Object System.Collections.ArrayList
    $add = {
        param($type, $kind, $path, $nosize)
        $ex = ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path))
        [void]$L.Add([pscustomobject]@{ Type = $type; Kind = $kind; Path = $path; Exists = $ex; IsFile = [IO.File]::Exists($path); NoSize = [bool]$nosize; SizeText = ''; StateText = $(if ($ex) { '存在' } else { '—' }) })
    }
    $hasTid = ($tid -notlike 'FILE:*')
    if ($hasTid) {
        $saveRoot = Join-Path $d 'nand\user\save\0000000000000000'
        $users = @(Get-SubDirs $saveRoot)
        $got = $false
        foreach ($u in $users) {
            $t = Join-Path $u $tid
            if ([IO.Directory]::Exists($t)) {
                $uid = [IO.Path]::GetFileName($u)
                & $add ('存档 [用户 ' + $uid.Substring(0, [Math]::Min(8, $uid.Length)) + '…]') 'save' $t $false
                $got = $true
            }
        }
        if (-not $got) {
            $ph = if ($users.Count -gt 0) { Join-Path $users[0] $tid } else { Join-Path $saveRoot "_未知用户_\$tid" }
            & $add '存档（尚未生成）' 'save' $ph $false
        }
        & $add '着色器缓存' 'shader' (Join-Path $d ('shader\' + $tid.ToLower())) $false
        & $add 'Mods (load)' 'mods' (Join-Path $d "load\$tid") $false
        & $add 'SDMC 内容' 'sdmc' (Join-Path $d "sdmc\atmosphere\contents\$tid") $false
        & $add '游戏专属配置' 'gconfig' (Join-Path $d "config\custom\$tid.ini") $false
    }
    & $add '全局配置 qt-config.ini' 'config' (Join-Path $d 'config\qt-config.ini') $false
    & $add '日志目录' 'log' (Join-Path $d 'log') $false
    & $add 'Keys' 'keys' (Join-Path $d 'keys') $false
    & $add '固件 (registered)' 'fw' (Join-Path $d 'nand\system\Contents\registered') $true
    & $add 'NX2 开关（用户，优先）' 'switch' (Join-Path $env:APPDATA 'eden\nx2_switches.txt') $false
    & $add 'NX2 开关（版本自带）' 'switch' (Join-Path $emu.Dir 'nx2_switches.txt') $false
    & $add '数据根目录' 'root' $d $true
    & $add '模拟器目录' 'emu' $emu.Dir $true
    if ($game.Dir) { & $add '游戏目录' 'game' $game.Dir $true }
    if ($hasTid -and [IO.Directory]::Exists($d)) {
        # 兜底：数据目录里其它以 TitleID 命名的文件夹（不同分支布局可能不同）
        $known = @{}; foreach ($x in $L) { $known[$x.Path.ToLower()] = 1 }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($d, 0))
        while ($queue.Count -gt 0) {
            $it = $queue.Dequeue(); $p = $it[0]; $depth = $it[1]
            if ([IO.Path]::GetFileName($p) -ieq $tid -and -not $known.ContainsKey($p.ToLower())) { & $add '其它 (TitleID 目录)' 'other' $p $false; continue }
            if ($depth -ge 6) { continue }
            foreach ($s in (Get-SubDirs $p)) { if ([IO.Path]::GetFileName($s) -ne 'registered') { $queue.Enqueue(@($s, ($depth + 1))) } }
        }
    }
    return ,$L
}
function Backup-Path([string]$path, $game, $emu, [string]$kind) {
    $dir = Join-Path (Join-Path $script:BackupRoot (Safe-Name (Game-Display $game))) (Safe-Name $kind)
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $zip = Join-Path $dir ((Safe-Name (Emu-Display $emu)) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
    if ([IO.Directory]::Exists($path)) {
        [IO.Compression.ZipFile]::CreateFromDirectory($path, $zip, [IO.Compression.CompressionLevel]::Fastest, $true)
    } elseif ([IO.File]::Exists($path)) {
        $za = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $path, [IO.Path]::GetFileName($path)) } finally { $za.Dispose() }
    } else { throw "路径不存在：$path" }
    return $zip
}

# ================================================================ 开关扫描
$script:SwitchCache = @{}
function Get-ExeSwitches([string]$exe) {
    if (-not $exe -or -not [IO.File]::Exists($exe)) { return ,@() }
    $fi = New-Object IO.FileInfo $exe
    $k = $exe.ToLower() + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
    if (-not $script:SwitchCache.ContainsKey($k)) {
        $s = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe))
        $set = New-Object 'System.Collections.Generic.SortedSet[string]'
        foreach ($m in [regex]::Matches($s, '(?:EDEN|YUZU|CITRON)_NX2_[A-Z0-9_]{2,}|EDEN_[A-Z][A-Z0-9_]{3,}')) { [void]$set.Add($m.Value) }
        $script:SwitchCache[$k] = @($set)
    }
    return ,$script:SwitchCache[$k]
}
function Get-EmuSwitches($emu) {
    $a = @(Get-ExeSwitches $emu.Exe)
    if ($emu.Cli -and $emu.Cli -ne $emu.Exe) { $a = @(@($a) + @(Get-ExeSwitches $emu.Cli) | Sort-Object -Unique) }
    return ,$a
}
function Get-SwitchDefaults($emu) {
    $h = @{}
    foreach ($f in @((Join-Path $emu.Dir 'nx2_switches.txt'), (Join-Path $env:APPDATA 'eden\nx2_switches.txt'))) {
        if (-not [IO.File]::Exists($f)) { continue }
        foreach ($line in [IO.File]::ReadAllLines($f)) {
            $m = [regex]::Match($line, '^\s*(#?)\s*([A-Z][A-Z0-9_]+)\s*=\s*(.*)$')
            if ($m.Success) {
                $src = if ($f -like "$env:APPDATA*") { '用户文件' } else { '自带文件' }
                $state = if ($m.Groups[1].Value) { '注释' } else { '生效' }
                $h[$m.Groups[2].Value] = @{ value = $m.Groups[3].Value.Trim(); where = "$src($state)" }
            }
        }
    }
    return $h
}

# ================================================================ 联机工具
function Get-LanIPs {
    $r = New-Object System.Collections.ArrayList
    try {
        foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback') { continue }
            foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
                $ip = $ua.Address.ToString()
                if ($ip -like '169.254.*') { continue }
                [void]$r.Add([pscustomobject]@{ Ip = $ip; Nic = $ni.Name })
            }
        }
    } catch { }
    return ,$r
}
function Set-IniValue([string]$file, [string]$section, [string]$key, [string]$value) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ([IO.File]::Exists($file)) { foreach ($l in [IO.File]::ReadAllLines($file)) { $lines.Add($l) } }
    else { $dir = [IO.Path]::GetDirectoryName($file); if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) } }
    $hdr = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq "[$section]") { $hdr = $i; break } }
    if ($hdr -lt 0) {
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add("[$section]"); $lines.Add("$key\default=false"); $lines.Add("$key=$value")
    } else {
        $end = $lines.Count
        for ($i = $hdr + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].TrimStart().StartsWith('[')) { $end = $i; break } }
        $gotV = $false; $gotD = $false
        for ($i = $hdr + 1; $i -lt $end; $i++) {
            if ($lines[$i].StartsWith("$key=")) { $lines[$i] = "$key=$value"; $gotV = $true }
            elseif ($lines[$i].StartsWith("$key\default=")) { $lines[$i] = "$key\default=false"; $gotD = $true }
        }
        if (-not $gotV) { $lines.Insert($hdr + 1, "$key=$value") }
        if (-not $gotD) { $lines.Insert($hdr + 1, "$key\default=false") }
    }
    [IO.File]::WriteAllLines($file, $lines, (New-Object Text.UTF8Encoding($false)))
}
function Get-EmuProcesses($emu) {
    $r = @()
    foreach ($n in @($emu.Gui, $emu.Cli)) {
        if (-not $n) { continue }
        $pn = [IO.Path]::GetFileNameWithoutExtension($n)
        foreach ($p in @(Get-Process -Name $pn -ErrorAction SilentlyContinue)) {
            try { if ($p.Path -and $p.Path.StartsWith($emu.Dir, [StringComparison]::OrdinalIgnoreCase)) { $r += $p } } catch { }
        }
    }
    return ,$r
}

# ================================================================ 界面：样式
$StylesXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="Bg" Color="#0F1115"/>
  <SolidColorBrush x:Key="Panel" Color="#171A21"/>
  <SolidColorBrush x:Key="Panel2" Color="#1F232C"/>
  <SolidColorBrush x:Key="Line" Color="#2B303B"/>
  <SolidColorBrush x:Key="Fg" Color="#E6E8EE"/>
  <SolidColorBrush x:Key="Sub" Color="#8C95A6"/>
  <SolidColorBrush x:Key="Accent" Color="#5B8CFF"/>
  <SolidColorBrush x:Key="Sel" Color="#22304D"/>
  <SolidColorBrush x:Key="Hover" Color="#252A35"/>

  <Style x:Key="Card" TargetType="Border">
    <Setter Property="Background" Value="{StaticResource Panel}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="12"/>
    <Setter Property="Padding" Value="14"/>
  </Style>
  <Style x:Key="SubCard" TargetType="Border">
    <Setter Property="Background" Value="{StaticResource Panel2}"/>
    <Setter Property="CornerRadius" Value="10"/>
    <Setter Property="Padding" Value="14"/>
  </Style>
  <Style x:Key="H" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Sub}"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,12,0,6"/>
  </Style>
  <Style x:Key="Title" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Fg}"/>
    <Setter Property="FontSize" Value="15"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>

  <Style TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Fg}"/>
    <Setter Property="Background" Value="{StaticResource Panel2}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="14,7"/>
    <Setter Property="Margin" Value="0,0,8,8"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="b" Property="BorderBrush" Value="#5B8CFF"/>
            </Trigger>
            <Trigger Property="IsPressed" Value="True">
              <Setter TargetName="b" Property="Opacity" Value="0.75"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="b" Property="Opacity" Value="0.4"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="#2F5FD0"/>
    <Setter Property="BorderBrush" Value="#3B6FE0"/>
    <Setter Property="Foreground" Value="White"/>
  </Style>
  <Style x:Key="Go" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="#238636"/>
    <Setter Property="BorderBrush" Value="#2EA043"/>
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="FontSize" Value="17"/>
    <Setter Property="FontWeight" Value="Bold"/>
    <Setter Property="Padding" Value="30,10"/>
  </Style>
  <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="#3D1A1C"/>
    <Setter Property="BorderBrush" Value="#6E2A2C"/>
    <Setter Property="Foreground" Value="#FFB4AF"/>
  </Style>
  <Style x:Key="Small" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Padding" Value="9,3"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
  </Style>
  <Style x:Key="Pill" TargetType="Button">
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="Margin" Value="0,0,6,6"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="12" Padding="11,4">
            <ContentPresenter/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="TextBox">
    <Setter Property="Background" Value="#0C0E12"/>
    <Setter Property="Foreground" Value="{StaticResource Fg}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="CaretBrush" Value="White"/>
    <Setter Property="SelectionBrush" Value="#5B8CFF"/>
    <Setter Property="Padding" Value="6,5"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>
  <Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="{StaticResource Fg}"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>
  <Style TargetType="RadioButton">
    <Setter Property="Foreground" Value="{StaticResource Fg}"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>

  <Style TargetType="ListBox">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
  </Style>
  <Style TargetType="ListBoxItem">
    <Setter Property="Foreground" Value="{StaticResource Fg}"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ListBoxItem">
          <Border x:Name="b" Background="{StaticResource Panel2}" BorderBrush="Transparent" BorderThickness="1"
                  CornerRadius="9" Margin="0,0,4,6" Padding="11,9">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource Hover}"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource Sel}"/>
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="TabControl">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="0,12,0,0"/>
  </Style>
  <Style TargetType="TabItem">
    <Setter Property="Foreground" Value="{StaticResource Sub}"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TabItem">
          <Border x:Name="b" Padding="14,8" Margin="0,0,4,0" BorderThickness="0,0,0,2" BorderBrush="Transparent"
                  Background="Transparent" CornerRadius="6,6,0,0">
            <ContentPresenter ContentSource="Header"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource Hover}"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter Property="Foreground" Value="{StaticResource Fg}"/>
              <Setter Property="FontWeight" Value="SemiBold"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="DataGrid">
    <Setter Property="Background" Value="{StaticResource Panel}"/>
    <Setter Property="Foreground" Value="{StaticResource Fg}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="RowBackground" Value="{StaticResource Panel}"/>
    <Setter Property="AlternatingRowBackground" Value="{StaticResource Panel2}"/>
    <Setter Property="HorizontalGridLinesBrush" Value="{StaticResource Line}"/>
    <Setter Property="GridLinesVisibility" Value="Horizontal"/>
    <Setter Property="HeadersVisibility" Value="Column"/>
    <Setter Property="AutoGenerateColumns" Value="False"/>
    <Setter Property="IsReadOnly" Value="True"/>
    <Setter Property="SelectionMode" Value="Single"/>
    <Setter Property="CanUserAddRows" Value="False"/>
    <Setter Property="RowHeight" Value="28"/>
  </Style>
  <Style TargetType="DataGridColumnHeader">
    <Setter Property="Background" Value="{StaticResource Panel2}"/>
    <Setter Property="Foreground" Value="{StaticResource Sub}"/>
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="BorderThickness" Value="0,0,1,1"/>
  </Style>
  <Style TargetType="DataGridCell">
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Style.Triggers>
      <Trigger Property="IsSelected" Value="True">
        <Setter Property="Background" Value="#2C4A85"/>
        <Setter Property="Foreground" Value="White"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style TargetType="ScrollBar">
    <Setter Property="Width" Value="8"/>
    <Setter Property="MinWidth" Value="8"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb"><Border Background="#3A4150" CornerRadius="4"/></ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="MinWidth" Value="0"/>
        <Setter Property="Height" Value="8"/>
        <Setter Property="MinHeight" Value="8"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track" IsDirectionReversed="False">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb"><Border Background="#3A4150" CornerRadius="4"/></ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
    </Style.Triggers>
  </Style>
</ResourceDictionary>
'@

# ================================================================ 界面：主窗口
$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="EmuManager" Width="1460" Height="920" MinWidth="1150" MinHeight="700"
        Background="#0F1115" Foreground="#E6E8EE" FontFamily="Microsoft YaHei UI" FontSize="13"
        WindowStartupLocation="CenterScreen">
  <Grid Margin="16,14,16,10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 顶栏 -->
    <DockPanel Grid.Row="0" Margin="0,0,0,14">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="BtnImport" Content="＋ 导入 zip 版本" Style="{StaticResource Primary}" Margin="0,0,8,0"/>
        <Button x:Name="BtnRescan" Content="⟳ 重新扫描" Margin="0,0,8,0"/>
        <Button x:Name="BtnSettings" Content="扫描目录" Margin="0,0,8,0"/>
        <Button x:Name="BtnDataDir" Content="管理器数据" Margin="0"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Border Width="40" Height="40" CornerRadius="11" Margin="0,0,12,0">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#5B8CFF" Offset="0"/>
              <GradientStop Color="#B45BFF" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <TextBlock Text="E" FontSize="22" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="EmuManager" FontSize="20" FontWeight="Bold"/>
          <TextBlock x:Name="SubTitle" Text="Eden / Eglantine 多版本管理 · 调试 · 联机" Foreground="#8C95A6" FontSize="12"/>
        </StackPanel>
      </StackPanel>
    </DockPanel>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="270"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="390"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- 游戏库 -->
      <Border Grid.Column="0" Style="{StaticResource Card}">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="2,0,0,10">
            <TextBlock x:Name="GameCount" DockPanel.Dock="Right" Foreground="#8C95A6" VerticalAlignment="Center"/>
            <TextBlock Text="游戏库" Style="{StaticResource Title}"/>
          </DockPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
            <Button x:Name="BtnGameRename" Content="重命名" Style="{StaticResource Small}"/>
            <Button x:Name="BtnGameDir" Content="打开目录" Style="{StaticResource Small}"/>
          </StackPanel>
          <ListBox x:Name="GamesList">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <StackPanel>
                  <TextBlock Text="{Binding Name}" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Text="{Binding TitleId}" FontFamily="Consolas" FontSize="11" Foreground="#8C95A6" Margin="0,2,0,0"/>
                  <TextBlock Text="{Binding Tags}" FontSize="11" Foreground="#7FA6FF" Margin="0,3,0,0"/>
                </StackPanel>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
        </DockPanel>
      </Border>

      <!-- 版本 -->
      <Border Grid.Column="2" Style="{StaticResource Card}">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="2,0,0,10">
            <TextBlock x:Name="EmuCount" DockPanel.Dock="Right" Foreground="#8C95A6" VerticalAlignment="Center"/>
            <StackPanel>
              <TextBlock Text="模拟器版本" Style="{StaticResource Title}"/>
              <TextBlock Text="色条 = 对所选游戏的测试结果 · 双击直接启动" Foreground="#8C95A6" FontSize="11"/>
            </StackPanel>
          </DockPanel>
          <WrapPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
            <Button x:Name="BtnEmuAlias" Content="别名 / 备注" Style="{StaticResource Small}" Margin="0,0,6,6"/>
            <Button x:Name="BtnEmuIsolate" Content="隔离数据" Style="{StaticResource Small}" Margin="0,0,6,6"/>
            <Button x:Name="BtnEmuDir" Content="程序目录" Style="{StaticResource Small}" Margin="0,0,6,6"/>
            <Button x:Name="BtnEmuData" Content="数据目录" Style="{StaticResource Small}" Margin="0,0,6,6"/>
          </WrapPanel>
          <ListBox x:Name="EmusList">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="4"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Border Grid.Column="0" CornerRadius="2" Background="{Binding StatusColor}"/>
                  <StackPanel Grid.Column="1" Margin="10,0,0,0">
                    <DockPanel>
                      <Border DockPanel.Dock="Right" CornerRadius="9" Padding="8,1" Background="{Binding StatusColor}" VerticalAlignment="Center">
                        <TextBlock Text="{Binding StatusText}" FontSize="11" Foreground="White"/>
                      </Border>
                      <TextBlock Text="{Binding Name}" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                    </DockPanel>
                    <TextBlock Text="{Binding Version}" FontSize="11" Foreground="#8C95A6" TextTrimming="CharacterEllipsis" Margin="0,2,0,5"/>
                    <WrapPanel>
                      <Border CornerRadius="4" Padding="6,1" Margin="0,0,5,4" Background="#24324F" Visibility="{Binding BranchVis}">
                        <TextBlock Text="{Binding Branch}" FontSize="11" Foreground="#9DB8FF"/>
                      </Border>
                      <Border CornerRadius="4" Padding="6,1" Margin="0,0,5,4" Background="#2A2F3A" Visibility="{Binding CommitVis}">
                        <TextBlock Text="{Binding Commit}" FontFamily="Consolas" FontSize="11" Foreground="#C9D1D9"/>
                      </Border>
                      <Border CornerRadius="4" Padding="6,1" Margin="0,0,5,4" Background="{Binding DataBg}">
                        <TextBlock Text="{Binding DataText}" FontSize="11" Foreground="{Binding DataFg}"/>
                      </Border>
                      <Border CornerRadius="4" Padding="6,1" Margin="0,0,5,4" Background="#2A2F3A" Visibility="{Binding RoomVis}">
                        <TextBlock Text="联机服务器" FontSize="11" Foreground="#C3A6FF"/>
                      </Border>
                      <Border CornerRadius="4" Padding="6,1" Margin="0,0,5,4" Background="#2A2F3A">
                        <TextBlock Text="{Binding Build}" FontSize="11" Foreground="#8C95A6"/>
                      </Border>
                    </WrapPanel>
                    <TextBlock Text="{Binding LastRun}" FontSize="11" Foreground="#8C95A6" Visibility="{Binding LastVis}"/>
                    <TextBlock Text="{Binding Note}" FontSize="11" Foreground="#D6B56B" TextWrapping="Wrap" Visibility="{Binding NoteVis}" Margin="0,2,0,0"/>
                  </StackPanel>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
        </DockPanel>
      </Border>

      <!-- 详情 -->
      <Border Grid.Column="4" Style="{StaticResource Card}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="2,0,0,0">
            <TextBlock x:Name="SelTitle" Text="请选择游戏和版本" FontSize="17" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="SelSub" Foreground="#8C95A6" FontSize="11" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
          </StackPanel>
          <TabControl x:Name="Tabs">

            <TabItem Header="启动与调试">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="14"/>
                    <ColumnDefinition Width="280"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Text="启动目标" Style="{StaticResource H}" Margin="0,0,0,6"/>
                    <ListBox x:Name="TargetsList" MaxHeight="130">
                      <ListBox.ItemTemplate>
                        <DataTemplate>
                          <StackPanel>
                            <TextBlock Text="{Binding Label}" FontWeight="SemiBold"/>
                            <TextBlock Text="{Binding Path}" FontSize="11" Foreground="#8C95A6" TextTrimming="CharacterEllipsis"/>
                          </StackPanel>
                        </DataTemplate>
                      </ListBox.ItemTemplate>
                    </ListBox>
                    <Button x:Name="BtnBrowseTarget" Content="选择其它文件…" Style="{StaticResource Small}" HorizontalAlignment="Left" Margin="0,2,0,0"/>
                    <TextBlock Text="前端与选项" Style="{StaticResource H}"/>
                    <WrapPanel>
                      <RadioButton x:Name="RbGui" Content="GUI" IsChecked="True" Margin="0,0,18,6"/>
                      <RadioButton x:Name="RbCli" Content="命令行（崩溃后保留控制台）" Margin="0,0,18,6"/>
                      <CheckBox x:Name="ChkFull" Content="全屏 -f" Margin="0,0,18,6"/>
                      <CheckBox x:Name="ChkAsk" Content="退出后记录结果" IsChecked="True" Margin="0,0,0,6"/>
                    </WrapPanel>
                    <DockPanel Margin="0,10,0,6">
                      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                        <Button x:Name="BtnSwitches" Content="可用开关 / 版本对比" Style="{StaticResource Small}"/>
                        <Button x:Name="BtnClearEnv" Content="清空" Style="{StaticResource Small}" Margin="0"/>
                      </StackPanel>
                      <TextBlock Text="环境变量 · 仅本次启动生效，优先于 nx2_switches.txt" Foreground="#8C95A6" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    </DockPanel>
                    <TextBox x:Name="EnvBox" AcceptsReturn="True" FontFamily="Consolas" FontSize="13" Height="150"
                             VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" VerticalContentAlignment="Top"/>
                    <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                      <Button x:Name="BtnLaunch" Content="▶  启动" Style="{StaticResource Go}" Margin="0,0,10,0"/>
                      <Button x:Name="BtnKill" Content="结束运行中的实例" Style="{StaticResource Danger}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock x:Name="RunningText" VerticalAlignment="Center" Foreground="#3FB950"/>
                    </StackPanel>
                  </StackPanel>
                  <Border Grid.Column="2" Style="{StaticResource SubCard}" VerticalAlignment="Top">
                    <StackPanel>
                      <TextBlock Text="兼容性记录" Style="{StaticResource Title}" FontSize="14"/>
                      <TextBlock x:Name="CompatSub" Foreground="#8C95A6" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,10"/>
                      <WrapPanel x:Name="PillPanel"/>
                      <TextBlock Text="备注" Style="{StaticResource H}" Margin="0,6,0,4"/>
                      <TextBox x:Name="NoteBox" AcceptsReturn="True" TextWrapping="Wrap" Height="120" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
                      <TextBlock x:Name="LastRunText" Foreground="#8C95A6" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,10"/>
                      <Button x:Name="BtnSaveCompat" Content="保存记录" Style="{StaticResource Primary}" HorizontalAlignment="Left" Margin="0"/>
                    </StackPanel>
                  </Border>
                </Grid>
              </ScrollViewer>
            </TabItem>

            <TabItem Header="存档 / 着色器 / 配置">
              <DockPanel>
                <WrapPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
                  <Button x:Name="BtnLocOpen" Content="打开位置"/>
                  <Button x:Name="BtnLocBackup" Content="备份为 zip"/>
                  <Button x:Name="BtnLocRestore" Content="从备份还原…"/>
                  <Button x:Name="BtnLocCopy" Content="复制到其它版本…"/>
                  <Button x:Name="BtnLocClear" Content="清空（先备份）" Style="{StaticResource Danger}"/>
                  <Button x:Name="BtnLocBackDir" Content="备份目录"/>
                  <Button x:Name="BtnLocSize" Content="计算大小"/>
                </WrapPanel>
                <DataGrid x:Name="LocGrid">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="类型" Binding="{Binding Type}" Width="170"/>
                    <DataGridTextColumn Header="路径" Binding="{Binding Path}" Width="*"/>
                    <DataGridTextColumn Header="大小" Binding="{Binding SizeText}" Width="90"/>
                    <DataGridTextColumn Header="状态" Binding="{Binding StateText}" Width="60"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </TabItem>

            <TabItem Header="联机房间">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="14"/>
                    <ColumnDefinition Width="290"/>
                  </Grid.ColumnDefinitions>
                  <Border Grid.Column="0" Style="{StaticResource SubCard}" VerticalAlignment="Top">
                    <StackPanel>
                      <DockPanel>
                        <Border x:Name="RoomBadge" DockPanel.Dock="Right" CornerRadius="11" Padding="10,3" Background="#3A4150" VerticalAlignment="Center">
                          <TextBlock x:Name="RoomState" Text="未运行" Foreground="White" FontSize="12"/>
                        </Border>
                        <StackPanel>
                          <TextBlock Text="创建房间" Style="{StaticResource Title}" FontSize="14"/>
                          <TextBlock Text="使用版本自带的房间服务器（eden-room），其他人用模拟器的「直接连接」加入" Foreground="#8C95A6" FontSize="11"/>
                        </StackPanel>
                      </DockPanel>
                      <TextBlock Text="服务器程序" Style="{StaticResource H}"/>
                      <ListBox x:Name="RoomExeList" MaxHeight="96">
                        <ListBox.ItemTemplate>
                          <DataTemplate>
                            <DockPanel>
                              <TextBlock Text="{Binding Path}" DockPanel.Dock="Right" FontSize="11" Foreground="#8C95A6" Margin="10,0,0,0" TextTrimming="CharacterEllipsis" MaxWidth="320"/>
                              <TextBlock Text="{Binding Label}" FontWeight="SemiBold"/>
                            </DockPanel>
                          </DataTemplate>
                        </ListBox.ItemTemplate>
                      </ListBox>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="72"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="14"/>
                          <ColumnDefinition Width="72"/>
                          <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                          <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="房间名" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="0" Grid.Column="1" x:Name="RoomName" Margin="0,4"/>
                        <TextBlock Grid.Row="0" Grid.Column="3" Text="端口" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="0" Grid.Column="4" x:Name="RoomPort" Margin="0,4"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="描述" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="4" x:Name="RoomDesc" Margin="0,4"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="最大人数" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="2" Grid.Column="1" x:Name="RoomMax" Margin="0,4"/>
                        <TextBlock Grid.Row="2" Grid.Column="3" Text="密码" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="2" Grid.Column="4" x:Name="RoomPass" Margin="0,4"/>
                        <TextBlock Grid.Row="3" Grid.Column="0" Text="首选游戏" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="3" Grid.Column="1" x:Name="RoomGame" Margin="0,4"/>
                        <TextBlock Grid.Row="3" Grid.Column="3" Text="游戏 ID" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="3" Grid.Column="4" x:Name="RoomGameId" FontFamily="Consolas" Margin="0,4"/>
                        <TextBlock Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="5" Text="公开到大厅（可选，留空 = 私人房间，只能用 IP 直连）" Style="{StaticResource H}" Margin="0,10,0,2"/>
                        <TextBlock Grid.Row="5" Grid.Column="0" Text="用户名" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="5" Grid.Column="1" x:Name="RoomUser" Margin="0,4"/>
                        <TextBlock Grid.Row="5" Grid.Column="3" Text="Token" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="5" Grid.Column="4" x:Name="RoomToken" Margin="0,4"/>
                        <TextBlock Grid.Row="6" Grid.Column="0" Text="Web API" Foreground="#8C95A6" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="6" Grid.Column="1" Grid.ColumnSpan="4" x:Name="RoomApi" Margin="0,4"/>
                      </Grid>
                      <WrapPanel Margin="0,12,0,0">
                        <Button x:Name="BtnRoomStart" Content="▶ 启动房间" Style="{StaticResource Primary}"/>
                        <Button x:Name="BtnRoomStop" Content="停止房间" Style="{StaticResource Danger}"/>
                        <Button x:Name="BtnRoomFw" Content="放行防火墙 (UDP)"/>
                        <Button x:Name="BtnRoomCopy" Content="复制地址"/>
                        <Button x:Name="BtnRoomLogDir" Content="日志目录"/>
                      </WrapPanel>
                      <TextBlock x:Name="RoomAddr" FontFamily="Consolas" Foreground="#7FA6FF" TextWrapping="Wrap" Margin="0,2,0,8"/>
                      <TextBox x:Name="RoomLog" IsReadOnly="True" FontFamily="Consolas" FontSize="12" Height="170" TextWrapping="Wrap"
                               VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="2" Style="{StaticResource SubCard}" VerticalAlignment="Top">
                    <StackPanel>
                      <TextBlock Text="加入房间" Style="{StaticResource Title}" FontSize="14"/>
                      <TextBlock Text="把地址写进当前所选版本的「多人游戏 → 直接连接」默认值，进模拟器后打开该窗口即可连接（有密码时在窗口里输入）。" Foreground="#8C95A6" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,4"/>
                      <TextBlock Text="昵称" Style="{StaticResource H}" Margin="0,8,0,4"/>
                      <TextBox x:Name="JoinNick"/>
                      <TextBlock Text="地址" Style="{StaticResource H}" Margin="0,8,0,4"/>
                      <TextBox x:Name="JoinIp" FontFamily="Consolas"/>
                      <TextBlock Text="端口" Style="{StaticResource H}" Margin="0,8,0,4"/>
                      <TextBox x:Name="JoinPort" FontFamily="Consolas"/>
                      <TextBlock x:Name="JoinTarget" Foreground="#8C95A6" FontSize="11" TextWrapping="Wrap" Margin="0,10,0,10"/>
                      <Button x:Name="BtnJoinLocal" Content="填入本机房间" HorizontalAlignment="Stretch" Margin="0,0,0,8"/>
                      <Button x:Name="BtnJoinWrite" Content="写入所选版本" HorizontalAlignment="Stretch" Margin="0,0,0,8"/>
                      <Button x:Name="BtnJoinLaunch" Content="写入并启动游戏" Style="{StaticResource Primary}" HorizontalAlignment="Stretch" Margin="0"/>
                    </StackPanel>
                  </Border>
                </Grid>
              </ScrollViewer>
            </TabItem>

            <TabItem Header="运行记录">
              <DockPanel>
                <WrapPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
                  <Button x:Name="BtnRunLog" Content="打开该次日志"/>
                  <Button x:Name="BtnRunAgain" Content="载入此配置" Style="{StaticResource Primary}"/>
                  <Button x:Name="BtnRunDir" Content="记录目录"/>
                </WrapPanel>
                <DataGrid x:Name="RunsGrid">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="时间" Binding="{Binding Time}" Width="140"/>
                    <DataGridTextColumn Header="游戏" Binding="{Binding GameName}" Width="120"/>
                    <DataGridTextColumn Header="版本" Binding="{Binding EmuName}" Width="150"/>
                    <DataGridTextColumn Header="前端" Binding="{Binding Fe}" Width="46"/>
                    <DataGridTextColumn Header="时长" Binding="{Binding Dur}" Width="60"/>
                    <DataGridTextColumn Header="退出码" Binding="{Binding ExitCode}" Width="150"/>
                    <DataGridTextColumn Header="结果" Binding="{Binding Result}" Width="80"/>
                    <DataGridTextColumn Header="环境变量" Binding="{Binding EnvShort}" Width="*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </TabItem>
          </TabControl>
        </DockPanel>
      </Border>
    </Grid>

    <!-- 状态栏 -->
    <DockPanel Grid.Row="2" Margin="2,10,2,0">
      <TextBlock x:Name="RunCount" DockPanel.Dock="Right" Foreground="#3FB950"/>
      <TextBlock x:Name="StatusText" Foreground="#8C95A6" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
  </Grid>
</Window>
'@

# ================================================================ 界面：加载
$script:App = [System.Windows.Application]::Current
if (-not $script:App) { $script:App = New-Object System.Windows.Application; $script:App.ShutdownMode = 'OnExplicitShutdown' }
$script:App.Resources = [Windows.Markup.XamlReader]::Parse($StylesXaml)

$script:win = [Windows.Markup.XamlReader]::Parse($MainXaml)
$script:ui = @{}
foreach ($m in [regex]::Matches($MainXaml, 'x:Name="(\w+)"')) { $ui[$m.Groups[1].Value] = $win.FindName($m.Groups[1].Value) }
$win.Title = "EmuManager $AppVersion"

function Set-Status([string]$t) {
    $ui.StatusText.Text = $t
    try { $win.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Background) } catch { }
}

# ---- 对话框工具
function Th([double]$a, $b = $null, $c = $null, $d = $null) {
    if ($null -eq $b) { return New-Object System.Windows.Thickness($a) }
    return New-Object System.Windows.Thickness($a, [double]$b, [double]$c, [double]$d)
}
function New-Dialog([string]$title, [int]$width = 460) {
    $w = New-Object System.Windows.Window
    $w.Title = $title; $w.Width = $width; $w.SizeToContent = 'Height'; $w.ResizeMode = 'NoResize'
    $w.WindowStartupLocation = 'CenterOwner'; $w.Owner = $script:win
    $w.Background = To-Brush '#171A21'; $w.Foreground = To-Brush '#E6E8EE'
    $w.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI'); $w.FontSize = 13
    return $w
}
function New-TB([string]$text, [string]$fg = '#E6E8EE', [double]$size = 13) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.Foreground = To-Brush $fg; $t.FontSize = $size; $t.TextWrapping = 'Wrap'
    return $t
}
function New-DlgButtons($w, [string]$okText = '确定') {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.HorizontalAlignment = 'Right'; $sp.Margin = (Th 0 16 0 0)
    $ok = New-Object System.Windows.Controls.Button; $ok.Content = $okText; $ok.Style = $script:App.Resources['Primary']; $ok.IsDefault = $true
    $no = New-Object System.Windows.Controls.Button; $no.Content = '取消'; $no.IsCancel = $true; $no.Margin = (Th 0)
    $ok.Add_Click({ $w.DialogResult = $true })
    [void]$sp.Children.Add($ok); [void]$sp.Children.Add($no)
    return $sp
}
# 多字段表单：$fields = @(@{L='标签'; V='默认值'}, ...)；返回字符串数组或 $null
function Show-Form([string]$title, $fields, [string]$hint = '') {
    $w = New-Dialog $title 520
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = (Th 20)
    if ($hint) { $h = New-TB $hint '#8C95A6' 12; $h.Margin = (Th 0 0 0 6); [void]$sp.Children.Add($h) }
    $boxes = @()
    foreach ($f in $fields) {
        $l = New-TB $f.L '#8C95A6' 12; $l.Margin = (Th 0 8 0 4); [void]$sp.Children.Add($l)
        $tb = New-Object System.Windows.Controls.TextBox; $tb.Text = [string]$f.V
        [void]$sp.Children.Add($tb); $boxes += $tb
    }
    [void]$sp.Children.Add((New-DlgButtons $w))
    $w.Content = $sp
    if ($boxes.Count -gt 0) { $w.Add_ContentRendered({ $boxes[0].Focus(); $boxes[0].SelectAll() }) }
    if ($w.ShowDialog() -eq $true) { return ,@($boxes | ForEach-Object { $_.Text }) }
    return $null
}
function Select-EmuDialog([string]$title, $exclude) {
    $cands = @($script:Emus | Where-Object { -not $exclude -or $_.Key -ne $exclude.Key })
    if ($cands.Count -eq 0) { Msg '没有其它版本。'; return $null }
    $w = New-Dialog $title 560
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = (Th 20)
    $lb = New-Object System.Windows.Controls.ListBox; $lb.MaxHeight = 360
    $lb.DisplayMemberPath = 'Text'
    $lb.ItemsSource = @($cands | ForEach-Object {
        $d = if ($_.Portable) { '独立数据' } else { '共享 %APPDATA%' }
        [pscustomobject]@{ Text = (Emu-Display $_) + '   ·   ' + $d + '   ·   ' + $_.Dir; Emu = $_ }
    })
    $lb.Add_MouseDoubleClick({ if ($lb.SelectedItem) { $w.DialogResult = $true } })
    [void]$sp.Children.Add($lb)
    [void]$sp.Children.Add((New-DlgButtons $w))
    $w.Content = $sp
    if ($w.ShowDialog() -eq $true -and $lb.SelectedItem) { return $lb.SelectedItem.Emu }
    return $null
}

# ================================================================ 状态与填充
$script:Emus = @()
$script:Games = @()
$script:Running = New-Object System.Collections.ArrayList
$script:Filling = $false
$script:PillSel = '未测试'
$script:Room = $null

function Get-SelEmu  { $i = $ui.EmusList.SelectedItem;  if ($i) { return $i.Emu }; return $null }
function Get-SelGame { $i = $ui.GamesList.SelectedItem; if ($i) { return $i.Game }; return $null }
function Get-SelLoc  { $i = $ui.LocGrid.SelectedItem;   if ($i) { return $i }; return $null }

function Fill-Games {
    $keep = $null; $g0 = Get-SelGame; if ($g0) { $keep = $g0.TitleId }
    $vms = @()
    foreach ($g in $script:Games) {
        $parts = @($g.Contents | Group-Object Kind | ForEach-Object { switch ($_.Name) { 'base' { '基础' } 'update' { "更新 ×$($_.Count)" } 'dlc' { "DLC ×$($_.Count)" } } })
        $vms += [pscustomobject]@{ Name = (Game-Display $g); TitleId = $g.TitleId; Tags = ($parts -join ' · '); Game = $g }
    }
    $script:Filling = $true
    $ui.GamesList.ItemsSource = $vms
    $idx = 0
    for ($i = 0; $i -lt $vms.Count; $i++) { if ($keep -and $vms[$i].TitleId -eq $keep) { $idx = $i } }
    if ($vms.Count -gt 0) { $ui.GamesList.SelectedIndex = $idx }
    $script:Filling = $false
    $ui.GameCount.Text = "$($vms.Count) 个"
}
function Fill-Emus {
    $keep = $null; $e0 = Get-SelEmu; if ($e0) { $keep = $e0.Key }
    $game = Get-SelGame
    $vms = @()
    foreach ($e in $script:Emus) {
        $st = '—'; $col = '#2A2F3A'; $last = ''
        if ($game) {
            $c = Get-Compat $e $game
            $st = [string]$c.status; if (-not $st) { $st = '未测试' }
            $col = $script:StatusHex[$st]; if (-not $col) { $col = '#3A4150' }
            if ($c.lastRun) { $last = '上次 ' + $c.lastRun + ' · ' + (Format-Duration ([int]$c.lastSeconds)) + ' · ' + $c.lastExit }
        }
        $note = ''; $em = $script:Db.emus[$e.Key]; if ($em -and $em.note) { $note = $em.note }
        $commit = if ($e.Commit) { $e.Commit.Substring(0, [Math]::Min(10, $e.Commit.Length)) } else { '' }
        $ver = if ($e.Version) { $e.Version } else { $e.Dir }
        $vms += [pscustomobject]@{
            Name = (Emu-Display $e); Version = $ver
            Branch = $e.Branch; BranchVis = $(if ($e.Branch) { 'Visible' } else { 'Collapsed' })
            Commit = $commit; CommitVis = $(if ($commit) { 'Visible' } else { 'Collapsed' })
            DataText = $(if ($e.Portable) { '独立数据' } else { '共享 %APPDATA%' })
            DataBg = $(if ($e.Portable) { '#16351F' } else { '#3A2C10' })
            DataFg = $(if ($e.Portable) { '#56D364' } else { '#E3B341' })
            RoomVis = $(if ($e.Room) { 'Visible' } else { 'Collapsed' })
            Build = $e.BuildDate.ToString('yyyy-MM-dd HH:mm')
            StatusText = $st; StatusColor = $col
            LastRun = $last; LastVis = $(if ($last) { 'Visible' } else { 'Collapsed' })
            Note = $note; NoteVis = $(if ($note) { 'Visible' } else { 'Collapsed' })
            Emu = $e
        }
    }
    $script:Filling = $true
    $ui.EmusList.ItemsSource = $vms
    $idx = 0
    for ($i = 0; $i -lt $vms.Count; $i++) { if ($keep -and $vms[$i].Emu.Key -eq $keep) { $idx = $i } }
    if ($vms.Count -gt 0) { $ui.EmusList.SelectedIndex = $idx }
    $script:Filling = $false
    $ui.EmuCount.Text = "$($vms.Count) 个"
}
function Fill-Targets {
    $game = Get-SelGame
    $vms = @()
    if ($game) {
        foreach ($c in $game.Contents) {
            if ($c.Kind -eq 'dlc') { continue }
            $vms += [pscustomobject]@{ Label = $c.Label; Path = $c.Launch }
        }
        $gdb = $script:Db.games[$game.TitleId]
        if ($gdb -and $gdb.customTarget -and -not (@($vms | ForEach-Object { $_.Path }) -contains $gdb.customTarget)) {
            $vms += [pscustomobject]@{ Label = '自定义'; Path = [string]$gdb.customTarget }
        }
    }
    $script:Filling = $true
    $ui.TargetsList.ItemsSource = $vms
    $idx = 0
    if ($game) {
        $gdb = $script:Db.games[$game.TitleId]
        if ($gdb -and $gdb.target) { for ($i = 0; $i -lt $vms.Count; $i++) { if ($vms[$i].Path -eq $gdb.target) { $idx = $i } } }
    }
    if ($vms.Count -gt 0) { $ui.TargetsList.SelectedIndex = $idx }
    $script:Filling = $false
}
function Load-Profile {
    $emu = Get-SelEmu; $game = Get-SelGame
    $ui.RbCli.IsEnabled = [bool]($emu -and $emu.Cli)
    $ui.RbGui.IsEnabled = [bool]($emu -and $emu.Gui)
    if ($emu) {
        $ui.RbGui.Content = if ($emu.Gui) { 'GUI · ' + [IO.Path]::GetFileName($emu.Gui) } else { 'GUI（此版本没有）' }
        $ui.RbCli.Content = if ($emu.Cli) { '命令行 · ' + [IO.Path]::GetFileName($emu.Cli) + '（保留控制台）' } else { '命令行（此版本没有）' }
        if ($ui.RbCli.IsChecked -and -not $emu.Cli) { $ui.RbGui.IsChecked = $true }
        if ($ui.RbGui.IsChecked -and -not $emu.Gui -and $emu.Cli) { $ui.RbCli.IsChecked = $true }
    }
    if (-not $emu -or -not $game) { return }
    $p = $script:Db.profiles[(Compat-Key $emu $game)]
    if (-not $p) { $p = $script:Db.profiles['*|' + $game.TitleId] }
    if ($p) {
        $ui.EnvBox.Text = [string]$p.env
        $ui.ChkFull.IsChecked = [bool]$p.fullscreen
        if ($p.cli -and $emu.Cli) { $ui.RbCli.IsChecked = $true } elseif ($emu.Gui) { $ui.RbGui.IsChecked = $true }
    }
}
function Save-Profile($emu, $game) {
    $p = @{ env = $ui.EnvBox.Text; fullscreen = [bool]$ui.ChkFull.IsChecked; cli = [bool]$ui.RbCli.IsChecked }
    $script:Db.profiles[(Compat-Key $emu $game)] = $p
    $script:Db.profiles['*|' + $game.TitleId] = $p
    if (-not $script:Db.games.ContainsKey($game.TitleId)) { $script:Db.games[$game.TitleId] = @{} }
    if ($ui.TargetsList.SelectedItem) { $script:Db.games[$game.TitleId].target = $ui.TargetsList.SelectedItem.Path }
}
function Build-Pills($panel, [scriptblock]$onClick) {
    $panel.Children.Clear()
    foreach ($s in $script:Statuses) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $script:App.Resources['Pill']; $b.Content = $s; $b.Tag = $s
        $b.Add_Click($onClick)
        [void]$panel.Children.Add($b)
    }
}
function Paint-Pills($panel, [string]$sel) {
    foreach ($b in $panel.Children) {
        $hex = $script:StatusHex[[string]$b.Tag]
        if ([string]$b.Tag -eq $sel) { $b.Background = To-Brush $hex; $b.BorderBrush = To-Brush '#E6E8EE'; $b.Opacity = 1 }
        else { $b.Background = To-Brush '#232833'; $b.BorderBrush = To-Brush $hex; $b.Opacity = 0.85 }
    }
}
function Load-Compat {
    $emu = Get-SelEmu; $game = Get-SelGame
    $ok = [bool]($emu -and $game)
    $ui.PillPanel.IsEnabled = $ok; $ui.NoteBox.IsEnabled = $ok; $ui.BtnSaveCompat.IsEnabled = $ok
    if (-not $ok) { return }
    $c = Get-Compat $emu $game
    $script:PillSel = [string]$c.status; if (-not $script:PillSel) { $script:PillSel = '未测试' }
    Paint-Pills $ui.PillPanel $script:PillSel
    $ui.NoteBox.Text = [string]$c.note
    $ui.CompatSub.Text = (Emu-Display $emu) + '  ×  ' + (Game-Display $game)
    $ui.LastRunText.Text = if ($c.lastRun) { '上次运行：' + $c.lastRun + "`n时长 " + (Format-Duration ([int]$c.lastSeconds)) + ' · 退出码 ' + $c.lastExit } else { '还没有运行记录' }
}
function Update-Header {
    $emu = Get-SelEmu; $game = Get-SelGame
    if ($emu -and $game) {
        $ui.SelTitle.Text = (Game-Display $game) + '   ×   ' + (Emu-Display $emu)
        $ui.SelSub.Text = $emu.Dir + '   ·   数据：' + $emu.DataDir
    } elseif ($game) { $ui.SelTitle.Text = Game-Display $game; $ui.SelSub.Text = '' }
    else { $ui.SelTitle.Text = '请选择游戏和版本'; $ui.SelSub.Text = '' }
    $ui.JoinTarget.Text = if ($emu) { '写入目标：' + (Emu-Display $emu) + "`n" + (Join-Path $emu.DataDir 'config\qt-config.ini') } else { '请先在中间选择一个版本' }
}
function Fill-Locations([bool]$withSize = $false) {
    $emu = Get-SelEmu; $game = Get-SelGame
    $rows = @()
    if ($emu -and $game) {
        if ($withSize) { Set-Status '正在计算大小…' }
        foreach ($l in (Get-GameLocations $emu $game)) {
            if ($withSize -and $l.Exists -and -not $l.NoSize) { $l.SizeText = Format-Size (Get-PathSize $l.Path) }
            $rows += $l
        }
        if ($withSize) { Set-Status '大小已更新' }
    }
    $ui.LocGrid.ItemsSource = $rows
}
function Fill-Runs {
    $rows = @()
    foreach ($r in $script:Db.runs) {
        $envShort = (([string]$r.Env -split "`r?`n") | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }) -join '; '
        $rows += [pscustomobject]@{
            Time = $r.Time; GameName = $r.GameName; EmuName = $r.EmuName; Fe = $(if ($r.Cli) { 'CLI' } else { 'GUI' })
            Dur = (Format-Duration ([int]$r.Seconds)); ExitCode = $r.ExitCode; Result = $r.Result; EnvShort = $envShort; Rec = $r
        }
    }
    $ui.RunsGrid.ItemsSource = $rows
}
function Update-SharedWarning {
    $shared = @($script:Emus | Where-Object { -not $_.Portable })
    $txt = "已发现 $($script:Emus.Count) 个版本、$($script:Games.Count) 个游戏。"
    if ($shared.Count -gt 1) { $txt += "  注意：$($shared.Count) 个版本共用 %APPDATA% 数据（存档/着色器/配置互相影响），可选中后点「隔离数据」。" }
    Set-Status $txt
}
function Fill-RoomExes {
    $vms = @()
    foreach ($e in $script:Emus) { if ($e.Room) { $vms += [pscustomobject]@{ Label = (Emu-Display $e); Path = $e.Room } } }
    $ui.RoomExeList.ItemsSource = $vms
    $sel = 0
    $saved = [string]$script:Db.room.exe
    for ($i = 0; $i -lt $vms.Count; $i++) { if ($vms[$i].Path -ieq $saved) { $sel = $i } }
    if ($vms.Count -gt 0) { $ui.RoomExeList.SelectedIndex = $sel }
    $ui.BtnRoomStart.IsEnabled = ($vms.Count -gt 0)
    if ($vms.Count -eq 0) { $ui.RoomAddr.Text = '没有找到 eden-room.exe（PokeDinner 等版本自带）。' }
}
function Rescan {
    Set-Status '正在扫描模拟器…'
    $script:Emus = Scan-Emus
    Set-Status '正在扫描游戏…'
    $script:Games = Scan-Games
    Fill-Games
    Fill-Emus
    Fill-Runs
    Fill-RoomExes
    On-SelectionChanged
    Update-SharedWarning
}
function On-SelectionChanged {
    if ($script:Filling) { return }
    Fill-Targets
    Load-Profile
    Load-Compat
    Update-Header
    Fill-Locations $false
}

# ================================================================ 启动 / 运行跟踪
function Parse-Env([string]$text) {
    $h = [ordered]@{}
    foreach ($line in ($text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $i = $l.IndexOf('=')
        if ($i -gt 0) { $h[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim() }
    }
    return $h
}
function Start-Run {
    $emu = Get-SelEmu; $game = Get-SelGame
    if (-not $emu -or -not $game) { Msg '请先选择游戏和模拟器版本。'; return }
    $t = $ui.TargetsList.SelectedItem
    if (-not $t) { Msg '没有可启动的目标。'; return }
    $target = [string]$t.Path
    if (-not [IO.File]::Exists($target)) { Msg "启动目标不存在：`n$target" 'Warning'; return }
    $useCli = [bool]$ui.RbCli.IsChecked
    $exe = if ($useCli) { $emu.Cli } else { $emu.Gui }
    if (-not $exe) { Msg '这个版本没有所选的前端。'; return }
    $same = @($script:Running | Where-Object { $_.DataDir -ieq $emu.DataDir })
    if ($same.Count -gt 0) {
        if (-not (Confirm "已有一个使用同一数据目录的实例在运行（$($same[0].EmuName)），同时运行可能互相覆盖存档/着色器。仍要启动吗？")) { return }
    }
    Save-Profile $emu $game; Save-Db

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runId = $stamp + '_' + (Safe-Name (Emu-Display $emu)) + '_' + (Safe-Name (Game-Display $game))
    $exitFile = Join-Path $script:RunsDir ($runId + '.exit')
    $argList = @()
    if ($ui.ChkFull.IsChecked) { $argList += '-f' }
    $argList += '-g'; $argList += ('"' + $target + '"')
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $true
    $psi.WorkingDirectory = $emu.Dir
    if ($useCli) {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/v:on /c "title EmuManager - ' + (Safe-Name (Emu-Display $emu)) + ' & "' + $exe + '" ' + ($argList -join ' ') +
            ' & echo. & echo [EmuManager] exit code !errorlevel! & >"' + $exitFile + '" echo !errorlevel! & pause"'
    } else {
        $psi.FileName = $exe
        $psi.Arguments = ($argList -join ' ')
    }
    $envPairs = Parse-Env $ui.EnvBox.Text
    $saved = @{}
    foreach ($k in @($envPairs.Keys)) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, [string]$envPairs[$k], 'Process')
    }
    try { $p = [Diagnostics.Process]::Start($psi) }
    finally { foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') } }
    if (-not $p) { Msg '启动失败（没有获得进程）。' 'Error'; return }
    $run = [pscustomobject]@{
        Id = $runId; Process = $p; EmuKey = $emu.Key; EmuName = (Emu-Display $emu); DataDir = $emu.DataDir
        Tid = $game.TitleId; GameName = (Game-Display $game); Start = (Get-Date); Cli = $useCli
        ExitFile = $exitFile; Env = $ui.EnvBox.Text; Target = $target
    }
    [void]$script:Running.Add($run)
    Set-Status ('已启动：' + $run.GameName + ' @ ' + $run.EmuName + '（' + $envPairs.Count + ' 个环境变量）')
    Update-RunLabel
}
function Update-RunLabel {
    $n = $script:Running.Count
    $t = if ($n -gt 0) { "● 运行中 $n 个实例" } else { '' }
    $ui.RunCount.Text = $t; $ui.RunningText.Text = $t
}
function Check-Runs {
    $done = @($script:Running | Where-Object { $_.Process.HasExited })
    if ($done.Count -gt 0) {
        $script:RunTimer.Stop()
        try { foreach ($r in $done) { $script:Running.Remove($r); Finish-Run $r } } finally { $script:RunTimer.Start() }
    }
    Update-RunLabel
}
function Finish-Run($r) {
    $dur = (Get-Date) - $r.Start
    $code = $null
    if ($r.Cli) {
        if ([IO.File]::Exists($r.ExitFile)) {
            $t = ([IO.File]::ReadAllText($r.ExitFile)).Trim()
            if ($t -match '^-?\d+$') { $code = [int64]$t }
            Remove-Item -LiteralPath $r.ExitFile -Force -ErrorAction SilentlyContinue
        }
    } else { try { $code = $r.Process.ExitCode } catch { } }
    $logCopy = ''
    $logDir = Join-Path $r.DataDir 'log'
    if ([IO.Directory]::Exists($logDir)) {
        $newest = Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $r.Start.AddSeconds(-5) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) {
            $logCopy = Join-Path $script:RunsDir ($r.Id + '.log')
            try { Copy-Item -LiteralPath $newest.FullName -Destination $logCopy -Force } catch { $logCopy = '' }
        }
    }
    $rec = @{
        Id = $r.Id; Time = $r.Start.ToString('yyyy-MM-dd HH:mm:ss'); EmuKey = $r.EmuKey; EmuName = $r.EmuName
        Tid = $r.Tid; GameName = $r.GameName; Seconds = [int]$dur.TotalSeconds; ExitCode = (Format-ExitCode $code)
        Log = $logCopy; Env = $r.Env; Target = $r.Target; Cli = $r.Cli; Result = ''
    }
    $script:Db.runs.Insert(0, $rec)
    while ($script:Db.runs.Count -gt 500) { $script:Db.runs.RemoveAt($script:Db.runs.Count - 1) }
    $k = $r.EmuKey + '|' + $r.Tid
    if (-not $script:Db.compat.ContainsKey($k)) { $script:Db.compat[$k] = @{ status = '未测试'; note = '' } }
    $c = $script:Db.compat[$k]
    $c.lastRun = $rec.Time; $c.lastSeconds = $rec.Seconds; $c.lastExit = $rec.ExitCode
    if ($ui.ChkAsk.IsChecked) { Ask-RunResult $rec $c }
    Save-Db
    Fill-Runs; Fill-Emus; Load-Compat
}
function Ask-RunResult($rec, $c) {
    $w = New-Dialog '这次运行怎么样？' 520
    $w.Topmost = $true
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = (Th 20)
    $t1 = New-TB ($rec.GameName + '  @  ' + $rec.EmuName) '#E6E8EE' 15; $t1.FontWeight = [System.Windows.FontWeights]::SemiBold
    $t2 = New-TB ('运行 ' + (Format-Duration $rec.Seconds) + ' · 退出码 ' + $rec.ExitCode) '#8C95A6' 12; $t2.Margin = (Th 0 4 0 12)
    $wp = New-Object System.Windows.Controls.WrapPanel
    $script:DlgSel = [string]$c.status; if (-not $script:DlgSel) { $script:DlgSel = '未测试' }
    Build-Pills $wp { $script:DlgSel = [string]$this.Tag; Paint-Pills $wp $script:DlgSel }
    Paint-Pills $wp $script:DlgSel
    $tl = New-TB '备注' '#8C95A6' 12; $tl.Margin = (Th 0 8 0 4)
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.AcceptsReturn = $true; $tb.TextWrapping = 'Wrap'; $tb.Height = 110; $tb.Text = [string]$c.note; $tb.VerticalContentAlignment = 'Top'
    foreach ($x in @($t1, $t2, $wp, $tl, $tb)) { [void]$sp.Children.Add($x) }
    [void]$sp.Children.Add((New-DlgButtons $w '保存'))
    $w.Content = $sp
    if ($w.ShowDialog() -eq $true) { $c.status = $script:DlgSel; $c.note = $tb.Text; $rec.Result = $c.status }
}

# ================================================================ 位置操作
function Do-LocBackup {
    $l = Get-SelLoc; $emu = Get-SelEmu; $game = Get-SelGame
    if (-not $l) { Msg '先在列表里选一项。'; return }
    if (-not $l.Exists) { Msg '该位置不存在。'; return }
    if ($l.NoSize) { if (-not (Confirm "这一项可能很大（$($l.Type)），确定要整体打包吗？")) { return } }
    Set-Status '正在备份…'
    $zip = Backup-Path $l.Path $game $emu $l.Type
    Set-Status "已备份：$zip"
}
function Do-LocClear {
    $l = Get-SelLoc; $emu = Get-SelEmu; $game = Get-SelGame
    if (-not $l -or -not $l.Exists) { Msg '先选一个存在的位置。'; return }
    if (@('shader', 'save', 'mods', 'sdmc', 'gconfig', 'other', 'log') -notcontains $l.Kind) { Msg '为安全起见，只允许清空：存档、着色器、Mods、SDMC、游戏专属配置、日志。'; return }
    if (-not (Confirm "将先把下面的内容打包备份，然后删除：`n$($l.Path)`n`n继续吗？")) { return }
    Set-Status '正在备份…'
    $zip = Backup-Path $l.Path $game $emu $l.Type
    Remove-Item -LiteralPath $l.Path -Recurse -Force
    Set-Status "已清空，备份在：$zip"
    Fill-Locations $false
}
function Do-LocRestore {
    $l = Get-SelLoc; $emu = Get-SelEmu; $game = Get-SelGame
    if (-not $l) { Msg '先选择要还原到的位置（如“存档”“着色器缓存”）。'; return }
    if ($l.Path -like '*_未知用户_*') { Msg '这个版本还没有用户存档目录，请先用它启动一次任意游戏，生成用户后再还原。'; return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'zip 备份|*.zip'
    $bd = Join-Path (Join-Path $script:BackupRoot (Safe-Name (Game-Display $game))) (Safe-Name $l.Type)
    if (-not [IO.Directory]::Exists($bd)) { $bd = Join-Path $script:BackupRoot (Safe-Name (Game-Display $game)) }
    if (-not [IO.Directory]::Exists($bd)) { $bd = $script:BackupRoot }
    $dlg.InitialDirectory = $bd
    if ($dlg.ShowDialog($script:win) -ne $true) { return }
    if (-not (Confirm "用`n$($dlg.FileName)`n覆盖`n$($l.Path)`n（现有内容会先自动备份）`n继续吗？")) { return }
    if ($l.Exists) { [void](Backup-Path $l.Path $game $emu $l.Type); Remove-Item -LiteralPath $l.Path -Recurse -Force }
    $parent = [IO.Path]::GetDirectoryName($l.Path)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $tmp = Join-Path $parent ('.emumgr_restore_' + (Get-Date -Format 'yyyyMMddHHmmss'))
    [IO.Compression.ZipFile]::ExtractToDirectory($dlg.FileName, $tmp)
    $entries = @(Get-ChildItem -LiteralPath $tmp -Force)
    if ($entries.Count -eq 1) {
        Move-Item -LiteralPath $entries[0].FullName -Destination $l.Path
        Remove-Item -LiteralPath $tmp -Recurse -Force
    } else {
        Move-Item -LiteralPath $tmp -Destination $l.Path
    }
    Set-Status "已还原到 $($l.Path)"
    Fill-Locations $false
}
function Do-LocCopy {
    $l = Get-SelLoc; $emu = Get-SelEmu; $game = Get-SelGame
    if (-not $l -or -not $l.Exists) { Msg '先选一个存在的位置（存档、着色器、Mods 等）。'; return }
    if (@('save', 'shader', 'mods', 'sdmc', 'gconfig', 'config', 'other') -notcontains $l.Kind) { Msg '这一项不支持复制。'; return }
    $dst = Select-EmuDialog '复制到哪个版本？' $emu
    if (-not $dst) { return }
    if (-not $l.Path.StartsWith($emu.DataDir, [StringComparison]::OrdinalIgnoreCase)) { Msg '该路径不在数据目录下，无法映射。'; return }
    $rel = $l.Path.Substring($emu.DataDir.TrimEnd('\').Length).TrimStart('\')
    $target = Join-Path $dst.DataDir $rel
    if ($l.Kind -eq 'save') {
        $uid = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($l.Path))
        $users = @(Get-SubDirs (Join-Path $dst.DataDir 'nand\user\save\0000000000000000'))
        $match = @($users | Where-Object { [IO.Path]::GetFileName($_) -ieq $uid })
        if ($users.Count -gt 0 -and $match.Count -eq 0) { $target = Join-Path $users[0] $game.TitleId }
    }
    if ($target -ieq $l.Path) { Msg '两个版本共用同一个数据目录，无需复制。'; return }
    if (-not (Confirm "复制`n$($l.Path)`n→`n$target`n（目标已有内容会先自动备份）`n继续吗？")) { return }
    if (Test-Path -LiteralPath $target) { [void](Backup-Path $target $game $dst $l.Type); Remove-Item -LiteralPath $target -Recurse -Force }
    $parent = [IO.Path]::GetDirectoryName($target)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    Set-Status '正在复制…'
    if ($l.IsFile) { Copy-Item -LiteralPath $l.Path -Destination $target -Force } else { Copy-Item -LiteralPath $l.Path -Destination $target -Recurse -Force }
    Set-Status "已复制到 $target"
}

# ================================================================ 版本操作
function Do-MakePortable($emu) {
    if (-not $emu) { $emu = Get-SelEmu }
    if (-not $emu) { return }
    if ($emu.Portable) { Msg "这个版本已经使用独立数据目录：`n$($emu.DataDir)"; return }
    $src = $emu.DataDir; $dst = Join-Path $emu.Dir 'user'
    $text = "将【$(Emu-Display $emu)】转为独立数据目录：`n会在 $dst 建立 user 文件夹，之后它不再与其它版本共享`n$src`n`n是 = 复制 keys、固件/存档(nand)、配置、mods（不含着色器缓存；nand 若装过游戏会比较大）`n否 = 只复制 keys 和固件（全新存档）`n取消 = 不操作"
    $r = [System.Windows.MessageBox]::Show($script:win, $text, 'EmuManager', 'YesNoCancel', 'Question')
    if ($r -eq 'Cancel') { return }
    [void][IO.Directory]::CreateDirectory($dst)
    $items = if ($r -eq 'Yes') { @('keys', 'nand', 'config', 'load', 'sdmc') } else { @('keys', 'nand\system') }
    foreach ($i in $items) {
        $s = Join-Path $src $i; $t = Join-Path $dst $i
        if ([IO.Directory]::Exists($s)) {
            Set-Status "正在复制 $i …"
            & robocopy.exe $s $t /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        }
    }
    Set-Status '已转为独立数据目录。'
    Rescan
}
function Do-ImportZip {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = '模拟器压缩包|*.zip'; $dlg.InitialDirectory = $script:Drive
    if ($dlg.ShowDialog($script:win) -ne $true) { return }
    $zipName = [IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
    $sha = ''; $m = [regex]::Match($zipName, '([0-9a-f]{12,40})'); if ($m.Success) { $sha = $m.Groups[1].Value }
    $def = $zipName -replace '-?windows-?x86_64', '' -replace '-?win(dows)?-?x64', ''
    if ($sha) { $def = $def.Replace($sha, $sha.Substring(0, 10)) }
    $vals = Show-Form '导入版本' @(@{ L = '文件夹名（解压到 ' + $script:Cfg.VersionsDir + '）'; V = $def })
    if (-not $vals -or -not $vals[0]) { return }
    $dest = Join-Path $script:Cfg.VersionsDir (Safe-Name $vals[0])
    if (Test-Path -LiteralPath $dest) { Msg "已存在：$dest" 'Warning'; return }
    Set-Status '正在解压…'
    [IO.Compression.ZipFile]::ExtractToDirectory($dlg.FileName, $dest)
    $files = @(Get-ChildItem -LiteralPath $dest -File -Force); $dirs = @(Get-ChildItem -LiteralPath $dest -Directory -Force)
    if ($files.Count -eq 0 -and $dirs.Count -eq 1 -and -not (Test-EmuDir $dest)) {
        foreach ($c in @(Get-ChildItem -LiteralPath $dirs[0].FullName -Force)) { Move-Item -LiteralPath $c.FullName -Destination $dest }
        Remove-Item -LiteralPath $dirs[0].FullName -Force -Recurse
    }
    $srcTxt = "source $([IO.Path]::GetFileName($dlg.FileName))`r`nimported $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`n"
    if ($sha) { $srcTxt += "commit $sha`r`n" }
    [IO.File]::WriteAllText((Join-Path $dest 'EMUMGR-SOURCE.txt'), $srcTxt)
    if (-not (Test-EmuDir $dest)) { Msg "解压完成，但没有在 $dest 找到模拟器 exe，请检查压缩包。" 'Warning' }
    Rescan
    $vms = @($ui.EmusList.ItemsSource)
    for ($i = 0; $i -lt $vms.Count; $i++) { if ($vms[$i].Emu.Dir -ieq $dest) { $ui.EmusList.SelectedIndex = $i } }
    $new = Get-SelEmu
    if ($new -and $new.Dir -ieq $dest -and (Confirm '导入完成。要把新版本设为独立数据目录吗？（推荐用于对比测试，避免与其它版本共享存档/着色器）')) { Do-MakePortable $new }
}
function Do-Settings {
    $vals = Show-Form '扫描目录设置' @(
        @{ L = '模拟器扫描目录（多个用 ; 分隔，扫描 3 层）'; V = (@($script:Cfg.EmuRoots) -join ';') },
        @{ L = '游戏扫描目录（识别 exefs\main.npdm 解包目录和 nsp/xci，扫描 5 层）'; V = (@($script:Cfg.GameRoots) -join ';') },
        @{ L = '导入 zip 时解压到的目录'; V = [string]$script:Cfg.VersionsDir }
    )
    if (-not $vals) { return }
    $split = { param($s) ,@($s -split ';' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) }
    if ($vals[0]) { $script:Cfg.EmuRoots = & $split $vals[0] }
    if ($vals[1]) { $script:Cfg.GameRoots = & $split $vals[1] }
    if ($vals[2]) { $script:Cfg.VersionsDir = $vals[2].Trim() }
    Write-Json $script:ConfigPath $script:Cfg
    Rescan
}
function Show-Switches {
    $emu = Get-SelEmu
    if (-not $emu) { return }
    Set-Status '正在读取 exe 中的开关…'
    $mine = Get-EmuSwitches $emu
    $defs = Get-SwitchDefaults $emu
    Set-Status ''
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="900" Height="680" WindowStartupLocation="CenterOwner"
        Background="#171A21" Foreground="#E6E8EE" FontFamily="Microsoft YaHei UI" FontSize="13">
  <DockPanel Margin="18">
    <StackPanel DockPanel.Dock="Top">
      <TextBlock x:Name="Hdr" FontSize="16" FontWeight="Bold"/>
      <TextBlock Text="双击一行 → 加入环境变量框。选择右侧版本可对比两者支持的开关（差异行高亮）。" Foreground="#8C95A6" FontSize="12" Margin="0,4,0,10"/>
    </StackPanel>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="230"/>
      </Grid.ColumnDefinitions>
      <DataGrid x:Name="Grid" Grid.Column="0">
        <DataGrid.RowStyle>
          <Style TargetType="DataGridRow">
            <Style.Triggers>
              <DataTrigger Binding="{Binding Diff}" Value="True">
                <Setter Property="Background" Value="#3A2F12"/>
              </DataTrigger>
            </Style.Triggers>
          </Style>
        </DataGrid.RowStyle>
        <DataGrid.Columns>
          <DataGridTextColumn Header="开关" Binding="{Binding Name}" Width="*"/>
          <DataGridTextColumn Header="本版本" Binding="{Binding A}" Width="60"/>
          <DataGridTextColumn Header="对比" Binding="{Binding B}" Width="50"/>
          <DataGridTextColumn Header="txt 中的值" Binding="{Binding V}" Width="90"/>
          <DataGridTextColumn Header="来源" Binding="{Binding W}" Width="110"/>
        </DataGrid.Columns>
      </DataGrid>
      <DockPanel Grid.Column="2">
        <TextBlock DockPanel.Dock="Top" Text="对比版本" Foreground="#8C95A6" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <ListBox x:Name="Cmp" DisplayMemberPath="Text"/>
      </DockPanel>
    </Grid>
  </DockPanel>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Parse($x)
    $w.Owner = $script:win
    $w.Title = '可用开关 — ' + (Emu-Display $emu)
    $grid = $w.FindName('Grid'); $cmp = $w.FindName('Cmp'); $hdr = $w.FindName('Hdr')
    $others = @([pscustomobject]@{ Text = '（不对比）'; Emu = $null }) + @($script:Emus | Where-Object { $_.Key -ne $emu.Key } | ForEach-Object { [pscustomobject]@{ Text = (Emu-Display $_); Emu = $_ } })
    $cmp.ItemsSource = $others
    $fill = {
        $other = @(); $hasCmp = $false
        $sel = $cmp.SelectedItem
        if ($sel -and $sel.Emu) { $other = Get-EmuSwitches $sel.Emu; $hasCmp = $true }
        $all = @(@($mine) + @($other) | Sort-Object -Unique)
        $rows = @()
        foreach ($n in $all) {
            $a = if ($mine -contains $n) { '✓' } else { '—' }
            $b = if ($hasCmp) { if ($other -contains $n) { '✓' } else { '—' } } else { '' }
            $v = ''; $wh = ''; if ($defs.ContainsKey($n)) { $v = $defs[$n].value; $wh = $defs[$n].where }
            $rows += [pscustomobject]@{ Name = $n; A = $a; B = $b; V = $v; W = $wh; Diff = ($hasCmp -and $a -ne $b) }
        }
        $grid.ItemsSource = $rows
        $hdr.Text = (Emu-Display $emu) + "  ·  $(@($mine).Count) 个开关" + $(if ($hasCmp) { "   vs   $($sel.Text)  ·  $(@($other).Count) 个" } else { '' })
    }
    $cmp.Add_SelectionChanged({ Safe { & $fill } })
    $grid.Add_MouseDoubleClick({
        Safe {
            $r = $grid.SelectedItem; if (-not $r) { return }
            $v = if ($r.V) { $r.V } else { '1' }
            $tb = $ui.EnvBox
            if ($tb.Text -and -not $tb.Text.EndsWith("`n")) { $tb.AppendText("`r`n") }
            $tb.AppendText($r.Name + '=' + $v + "`r`n")
            Set-Status ('已加入 ' + $r.Name + '=' + $v)
        }
    })
    $cmp.SelectedIndex = 0
    & $fill
    [void]$w.ShowDialog()
}

# ================================================================ 联机房间
function Load-RoomForm {
    $r = $script:Db.room
    $game = Get-SelGame
    $ui.RoomName.Text = if ($r.name) { [string]$r.name } else { "$env:USERNAME 的房间" }
    $ui.RoomDesc.Text = [string]$r.desc
    $ui.RoomPort.Text = if ($r.port) { [string]$r.port } else { '24872' }
    $ui.RoomMax.Text = if ($r.max) { [string]$r.max } else { '4' }
    $ui.RoomPass.Text = [string]$r.pass
    $ui.RoomGame.Text = if ($r.game) { [string]$r.game } elseif ($game) { Game-Display $game } else { '' }
    $ui.RoomGameId.Text = if ($r.gameId) { [string]$r.gameId } elseif ($game) { $game.TitleId } else { '' }
    $ui.RoomUser.Text = [string]$r.user; $ui.RoomToken.Text = [string]$r.token; $ui.RoomApi.Text = [string]$r.api
    $ui.JoinNick.Text = if ($r.joinNick) { [string]$r.joinNick } else { $env:USERNAME }
    $ui.JoinIp.Text = if ($r.joinIp) { [string]$r.joinIp } else { '127.0.0.1' }
    $ui.JoinPort.Text = if ($r.joinPort) { [string]$r.joinPort } else { '24872' }
}
function Save-RoomForm {
    $r = $script:Db.room
    $r.name = $ui.RoomName.Text; $r.desc = $ui.RoomDesc.Text; $r.port = $ui.RoomPort.Text; $r.max = $ui.RoomMax.Text
    $r.pass = $ui.RoomPass.Text; $r.game = $ui.RoomGame.Text; $r.gameId = $ui.RoomGameId.Text
    $r.user = $ui.RoomUser.Text; $r.token = $ui.RoomToken.Text; $r.api = $ui.RoomApi.Text
    $r.joinNick = $ui.JoinNick.Text; $r.joinIp = $ui.JoinIp.Text; $r.joinPort = $ui.JoinPort.Text
    if ($ui.RoomExeList.SelectedItem) { $r.exe = $ui.RoomExeList.SelectedItem.Path }
    Save-Db
}
function Q([string]$s) { return '"' + ($s -replace '"', '') + '"' }
function Set-RoomState([string]$text, [string]$hex) { $ui.RoomState.Text = $text; $ui.RoomBadge.Background = To-Brush $hex }
function Update-RoomAddr {
    $port = $ui.RoomPort.Text.Trim()
    $ips = @(Get-LanIPs)
    if ($ips.Count -eq 0) { $ui.RoomAddr.Text = "本机：127.0.0.1:$port"; return }
    $ui.RoomAddr.Text = '局域网地址：' + (($ips | ForEach-Object { "$($_.Ip):$port（$($_.Nic)）" }) -join '   ') + "`n外网联机需要在路由器上把 UDP $port 转发到本机，或使用组网工具（ZeroTier / Tailscale 等）。"
}
function Start-Room {
    if ($script:Room -and -not $script:Room.Proc.HasExited) { Msg '房间已经在运行。'; return }
    $exe = $ui.RoomExeList.SelectedItem
    if (-not $exe) { Msg '没有可用的房间服务器（eden-room.exe）。'; return }
    $name = $ui.RoomName.Text.Trim(); $port = $ui.RoomPort.Text.Trim(); $max = $ui.RoomMax.Text.Trim()
    $game = $ui.RoomGame.Text.Trim(); $gid = $ui.RoomGameId.Text.Trim()
    if (-not $name) { Msg '请填写房间名。'; return }
    if ($port -notmatch '^\d+$' -or [int]$port -lt 1 -or [int]$port -gt 65535) { Msg '端口需要是 1–65535 的数字。'; return }
    if ($max -notmatch '^\d+$' -or [int]$max -lt 2 -or [int]$max -gt 254) { Msg '最大人数需要在 2–254 之间。'; return }
    if (-not $game) { Msg '请填写首选游戏名称（左侧选中游戏会自动带入）。'; return }
    if ($gid -notmatch '^(0x)?[0-9A-Fa-f]{1,16}$') { Msg '游戏 ID 需要是 16 位十六进制 TitleID。'; return }
    $gid = $gid -replace '^0x', ''
    Save-RoomForm
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log = Join-Path $script:RoomDir "room-$stamp.log"
    $con = Join-Path $script:RoomDir "room-$stamp.console.txt"
    $ban = Join-Path $script:RoomDir 'banlist.txt'
    $a = @('-n', (Q $name), '-p', $port, '-m', $max, '-g', (Q $game), '-i', $gid, '-l', (Q $log), '-b', (Q $ban))
    if ($ui.RoomDesc.Text.Trim()) { $a += @('-d', (Q $ui.RoomDesc.Text.Trim())) }
    if ($ui.RoomPass.Text) { $a += @('-w', (Q $ui.RoomPass.Text)) }
    if ($ui.RoomUser.Text.Trim()) { $a += @('-u', (Q $ui.RoomUser.Text.Trim())) }
    if ($ui.RoomToken.Text.Trim()) { $a += @('-t', (Q $ui.RoomToken.Text.Trim())) }
    if ($ui.RoomApi.Text.Trim()) { $a += @('-a', (Q $ui.RoomApi.Text.Trim())) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/c ""' + $exe.Path + '" ' + ($a -join ' ') + ' > "' + $con + '" 2>&1"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = [IO.Path]::GetDirectoryName($exe.Path)
    $p = [Diagnostics.Process]::Start($psi)
    $script:Room = [pscustomobject]@{ Proc = $p; Log = $log; Con = $con; LogPos = [int64]0; ConPos = [int64]0; Port = $port; Start = (Get-Date) }
    $ui.RoomLog.Text = "[EmuManager] 启动：$($exe.Path)`r`n[EmuManager] 参数：$(($a -join ' ') -replace '-w "[^"]*"', '-w "***"')`r`n"
    Set-RoomState "运行中 · UDP $port" '#238636'
    Update-RoomAddr
    $ui.JoinPort.Text = $port
    $script:RoomTimer.Start()
    Set-Status "房间已启动（UDP $port）。"
}
function Read-Tail([string]$file, [ref]$pos) {
    if (-not [IO.File]::Exists($file)) { return '' }
    try {
        $fs = New-Object IO.FileStream($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -le $pos.Value) { return '' }
            [void]$fs.Seek($pos.Value, [IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ($fs.Length - $pos.Value)
            $n = $fs.Read($buf, 0, $buf.Length)
            $pos.Value += $n
            return [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        } finally { $fs.Dispose() }
    } catch { return '' }
}
function Room-Tick {
    $r = $script:Room
    if (-not $r) { $script:RoomTimer.Stop(); return }
    $lp = $r.LogPos; $cp = $r.ConPos
    $t = (Read-Tail $r.Log ([ref]$lp)) + (Read-Tail $r.Con ([ref]$cp))
    $r.LogPos = $lp; $r.ConPos = $cp
    if ($t) {
        $ui.RoomLog.AppendText(($t -replace "(?<!`r)`n", "`r`n"))
        if ($ui.RoomLog.Text.Length -gt 60000) { $ui.RoomLog.Text = $ui.RoomLog.Text.Substring($ui.RoomLog.Text.Length - 40000) }
        $ui.RoomLog.ScrollToEnd()
    }
    if ($r.Proc.HasExited) {
        $script:RoomTimer.Stop()
        $code = ''; try { $code = Format-ExitCode $r.Proc.ExitCode } catch { }
        $ui.RoomLog.AppendText("[EmuManager] 房间服务器已退出（$code）`r`n"); $ui.RoomLog.ScrollToEnd()
        Set-RoomState '已停止' '#3A4150'
        $script:Room = $null
    }
}
function Stop-Room {
    if (-not $script:Room) { Msg '房间没有在运行。'; return }
    try { & taskkill.exe /PID $script:Room.Proc.Id /T /F | Out-Null } catch { }
    Start-Sleep -Milliseconds 300
    Room-Tick
}
function Do-Firewall {
    $port = $ui.RoomPort.Text.Trim()
    if ($port -notmatch '^\d+$') { Msg '端口不正确。'; return }
    $cmdArgs = "/c netsh advfirewall firewall add rule name=EmuManagerRoomUDP$port dir=in action=allow protocol=UDP localport=$port & echo. & echo Done. Press any key to close. & pause"
    try { Start-Process -FilePath $env:ComSpec -ArgumentList $cmdArgs -Verb RunAs } catch { Msg '已取消（需要管理员权限）。' }
}
function Do-JoinWrite([bool]$launch) {
    $emu = Get-SelEmu
    if (-not $emu) { Msg '请先在中间选择要写入的模拟器版本。'; return }
    $nick = $ui.JoinNick.Text.Trim(); $ip = $ui.JoinIp.Text.Trim(); $port = $ui.JoinPort.Text.Trim()
    if (-not $nick -or -not $ip -or $port -notmatch '^\d+$') { Msg '请填写昵称、地址和端口。'; return }
    $running = Get-EmuProcesses $emu
    if ($running.Count -gt 0) { Msg '这个版本正在运行，模拟器退出时会覆盖配置。请先关闭它再写入。' 'Warning'; return }
    Save-RoomForm
    $ini = Join-Path $emu.DataDir 'config\qt-config.ini'
    if ([IO.File]::Exists($ini)) { Copy-Item -LiteralPath $ini -Destination ($ini + '.emumgr.bak') -Force }
    Set-IniValue $ini 'Multiplayer' 'nickname' $nick
    Set-IniValue $ini 'Multiplayer' 'ip' $ip
    Set-IniValue $ini 'Multiplayer' 'port' $port
    Set-Status "已写入 $ini（[Multiplayer] nickname/ip/port），原文件备份为 .emumgr.bak"
    if ($launch) { $ui.Tabs.SelectedIndex = 0; Start-Run }
    else { Msg "已写入。启动游戏后在模拟器菜单「多人游戏 → 直接连接」里确认地址并连接。" }
}

# ================================================================ 事件绑定
$ui.BtnRescan.Add_Click({ Safe { Rescan } })
$ui.BtnSettings.Add_Click({ Safe { Do-Settings } })
$ui.BtnDataDir.Add_Click({ Safe { Open-InExplorer $script:DataRoot } })
$ui.BtnImport.Add_Click({ Safe { Do-ImportZip } })

$ui.GamesList.Add_SelectionChanged({ Safe { if (-not $script:Filling -and $ui.GamesList.SelectedItem) { Fill-Emus; On-SelectionChanged } } })
$ui.EmusList.Add_SelectionChanged({ Safe { if (-not $script:Filling -and $ui.EmusList.SelectedItem) { On-SelectionChanged } } })
$ui.EmusList.Add_MouseDoubleClick({ Safe { if ($ui.EmusList.SelectedItem) { Start-Run } } })
$ui.TargetsList.Add_SelectionChanged({
    Safe {
        if ($script:Filling) { return }
        $g = Get-SelGame; $t = $ui.TargetsList.SelectedItem
        if ($g -and $t) {
            if (-not $script:Db.games.ContainsKey($g.TitleId)) { $script:Db.games[$g.TitleId] = @{} }
            $script:Db.games[$g.TitleId].target = $t.Path
        }
    }
})

$ui.BtnGameRename.Add_Click({
    Safe {
        $g = Get-SelGame; if (-not $g) { return }
        $v = Show-Form '游戏名称' @(@{ L = '显示名称'; V = (Game-Display $g) })
        if ($v -and $v[0]) {
            if (-not $script:Db.games.ContainsKey($g.TitleId)) { $script:Db.games[$g.TitleId] = @{} }
            $script:Db.games[$g.TitleId].alias = $v[0]; Save-Db; Fill-Games; Update-Header
        }
    }
})
$ui.BtnGameDir.Add_Click({ Safe { $g = Get-SelGame; if ($g -and $g.Dir) { Open-InExplorer $g.Dir } } })
$ui.BtnEmuAlias.Add_Click({
    Safe {
        $emu = Get-SelEmu; if (-not $emu) { return }
        if (-not $script:Db.emus.ContainsKey($emu.Key)) { $script:Db.emus[$emu.Key] = @{} }
        $e = $script:Db.emus[$emu.Key]
        $v = Show-Form '版本别名 / 备注' @(@{ L = '别名（留空 = 用文件夹名）'; V = [string]$e.alias }, @{ L = '备注（分支特点、来源等）'; V = [string]$e.note }) $emu.Dir
        if ($v) { $e.alias = $v[0]; $e.note = $v[1]; Save-Db; Fill-Emus; Update-Header; Fill-RoomExes }
    }
})
$ui.BtnEmuIsolate.Add_Click({ Safe { Do-MakePortable $null } })
$ui.BtnEmuDir.Add_Click({ Safe { $e = Get-SelEmu; if ($e) { Open-InExplorer $e.Dir } } })
$ui.BtnEmuData.Add_Click({ Safe { $e = Get-SelEmu; if ($e) { Open-InExplorer $e.DataDir } } })

$ui.BtnBrowseTarget.Add_Click({
    Safe {
        $g = Get-SelGame; if (-not $g) { return }
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = '游戏文件 (main, nsp, xci, nca, nro)|main;*.nsp;*.xci;*.nca;*.nro;*.nso;*.nsz;*.xcz|所有文件|*.*'
        if ($g.Dir) { $dlg.InitialDirectory = $g.Dir }
        if ($dlg.ShowDialog($win) -eq $true) {
            if (-not $script:Db.games.ContainsKey($g.TitleId)) { $script:Db.games[$g.TitleId] = @{} }
            $script:Db.games[$g.TitleId].customTarget = $dlg.FileName
            $script:Db.games[$g.TitleId].target = $dlg.FileName
            Save-Db; Fill-Targets
        }
    }
})
$ui.BtnLaunch.Add_Click({ Safe { Start-Run } })
$ui.BtnKill.Add_Click({
    Safe {
        if ($script:Running.Count -eq 0) { Msg '没有由管理器启动、仍在运行的实例。'; return }
        $names = ($script:Running | ForEach-Object { $_.GameName + ' @ ' + $_.EmuName }) -join "`n"
        if (Confirm "强制结束以下实例？`n$names") {
            foreach ($r in @($script:Running)) {
                try { if ($r.Cli) { & taskkill.exe /PID $r.Process.Id /T /F | Out-Null } else { $r.Process.Kill() } } catch { }
            }
        }
    }
})
$ui.BtnSwitches.Add_Click({ Safe { Show-Switches } })
$ui.BtnClearEnv.Add_Click({ $ui.EnvBox.Text = '' })
Build-Pills $ui.PillPanel { $script:PillSel = [string]$this.Tag; Paint-Pills $ui.PillPanel $script:PillSel }
$ui.BtnSaveCompat.Add_Click({
    Safe {
        $emu = Get-SelEmu; $game = Get-SelGame; if (-not ($emu -and $game)) { return }
        $c = Get-Compat $emu $game
        $c.status = $script:PillSel; $c.note = $ui.NoteBox.Text
        Save-Db; Fill-Emus; Set-Status '兼容性记录已保存。'
    }
})

$ui.BtnLocOpen.Add_Click({ Safe { $l = Get-SelLoc; if ($l) { Open-InExplorer $l.Path } } })
$ui.LocGrid.Add_MouseDoubleClick({ Safe { $l = Get-SelLoc; if ($l) { Open-InExplorer $l.Path } } })
$ui.BtnLocBackup.Add_Click({ Safe { Do-LocBackup } })
$ui.BtnLocClear.Add_Click({ Safe { Do-LocClear } })
$ui.BtnLocRestore.Add_Click({ Safe { Do-LocRestore } })
$ui.BtnLocCopy.Add_Click({ Safe { Do-LocCopy } })
$ui.BtnLocBackDir.Add_Click({ Safe { $g = Get-SelGame; $p = $script:BackupRoot; if ($g) { $q = Join-Path $p (Safe-Name (Game-Display $g)); if ([IO.Directory]::Exists($q)) { $p = $q } }; Open-InExplorer $p } })
$ui.BtnLocSize.Add_Click({ Safe { Fill-Locations $true } })

$ui.BtnRoomStart.Add_Click({ Safe { Start-Room } })
$ui.BtnRoomStop.Add_Click({ Safe { Stop-Room } })
$ui.BtnRoomFw.Add_Click({ Safe { Do-Firewall } })
$ui.BtnRoomCopy.Add_Click({
    Safe {
        $port = $ui.RoomPort.Text.Trim()
        $ips = @(Get-LanIPs | ForEach-Object { "$($_.Ip):$port" })
        if ($ips.Count -eq 0) { $ips = @("127.0.0.1:$port") }
        [System.Windows.Clipboard]::SetText(($ips -join "`r`n"))
        Set-Status ('已复制：' + ($ips -join '  '))
    }
})
$ui.BtnRoomLogDir.Add_Click({ Safe { Open-InExplorer $script:RoomDir } })
$ui.RoomPort.Add_LostFocus({ Safe { Update-RoomAddr } })
$ui.BtnJoinLocal.Add_Click({ $ui.JoinIp.Text = '127.0.0.1'; $ui.JoinPort.Text = $ui.RoomPort.Text.Trim() })
$ui.BtnJoinWrite.Add_Click({ Safe { Do-JoinWrite $false } })
$ui.BtnJoinLaunch.Add_Click({ Safe { Do-JoinWrite $true } })

$ui.BtnRunLog.Add_Click({
    Safe {
        $row = $ui.RunsGrid.SelectedItem; if (-not $row) { return }
        $r = $row.Rec
        if ($r.Log -and [IO.File]::Exists($r.Log)) { Start-Process notepad.exe -ArgumentList ('"' + $r.Log + '"') } else { Msg '这次运行没有捕获到日志（模拟器可能没写日志，或日志目录不在数据目录下）。' }
    }
})
$ui.RunsGrid.Add_MouseDoubleClick({ Safe { $ui.BtnRunLog.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })
$ui.BtnRunDir.Add_Click({ Safe { Open-InExplorer $script:RunsDir } })
$ui.BtnRunAgain.Add_Click({
    Safe {
        $row = $ui.RunsGrid.SelectedItem; if (-not $row) { return }
        $r = $row.Rec
        $gv = @($ui.GamesList.ItemsSource)
        for ($i = 0; $i -lt $gv.Count; $i++) { if ($gv[$i].TitleId -eq $r.Tid) { $ui.GamesList.SelectedIndex = $i } }
        $ev = @($ui.EmusList.ItemsSource)
        for ($i = 0; $i -lt $ev.Count; $i++) { if ($ev[$i].Emu.Key -eq $r.EmuKey) { $ui.EmusList.SelectedIndex = $i } }
        $ui.EnvBox.Text = [string]$r.Env
        if ($r.Cli -and $ui.RbCli.IsEnabled) { $ui.RbCli.IsChecked = $true } elseif ($ui.RbGui.IsEnabled) { $ui.RbGui.IsChecked = $true }
        $tv = @($ui.TargetsList.ItemsSource)
        for ($i = 0; $i -lt $tv.Count; $i++) { if ($tv[$i].Path -eq [string]$r.Target) { $ui.TargetsList.SelectedIndex = $i } }
        $ui.Tabs.SelectedIndex = 0
        Set-Status '已载入该次运行的配置，点「启动」即可复现。'
    }
})
$ui.Tabs.Add_SelectionChanged({
    Safe {
        if ($_.OriginalSource -ne $ui.Tabs) { return }
        if ($ui.Tabs.SelectedIndex -eq 1) { Fill-Locations $false }
        if ($ui.Tabs.SelectedIndex -eq 2) { Update-RoomAddr }
    }
})

$script:RunTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:RunTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:RunTimer.Add_Tick({ Safe { Check-Runs } })
$script:RoomTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:RoomTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:RoomTimer.Add_Tick({ Safe { Room-Tick } })

$win.Add_KeyDown({ if ($_.Key -eq 'F5') { Safe { Rescan } } })
$win.Add_ContentRendered({
    Safe {
        Rescan
        Load-RoomForm
        Update-RoomAddr
        $script:RunTimer.Start()
    }
})
$win.Add_Closing({
    try { Save-RoomForm } catch { }
    if ($script:Room -and -not $script:Room.Proc.HasExited) {
        if (Confirm '联机房间还在运行，关闭管理器时一起停止房间吗？（选“否”则房间继续在后台运行）') {
            try { & taskkill.exe /PID $script:Room.Proc.Id /T /F | Out-Null } catch { }
        }
    }
    if ($script:Running.Count -gt 0) {
        [void][System.Windows.MessageBox]::Show($win, '还有模拟器实例在运行，关闭管理器后这些运行不会被记录（模拟器本身不受影响）。', 'EmuManager')
    }
    try { Save-Db } catch { }
})

[void]$win.ShowDialog()
