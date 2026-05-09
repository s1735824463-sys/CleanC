<# 
  C盘清理助手
  先扫描、再解释、再选择、再确认、再清理、最后写日志。
#>

param(
    [switch]$SmokeTest
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Get-ScriptDirectory {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    if ($PSCommandPath) {
        return (Split-Path -Parent $PSCommandPath)
    }
    if ($MyInvocation.MyCommand.Path) {
        return (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
    return (Get-Location).Path
}

$script:AppName = "C盘清理助手"
$script:StartTime = Get-Date
$script:ScriptRoot = Get-ScriptDirectory
$script:LogRoot = Join-Path $script:ScriptRoot "清理日志"
$script:LogDayFolder = Join-Path $script:LogRoot (Get-Date -Format "yyyy_MM_dd")
$script:LogFileName = "C盘清理日志_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss")
$script:LogPath = Join-Path $script:LogDayFolder $script:LogFileName
$script:LogAvailable = $true
$script:LogBuffer = New-Object System.Collections.Generic.List[string]
$script:TargetDriveLetter = "C"
$script:TargetDrive = "$($script:TargetDriveLetter):"
$script:TargetRoot = "$($script:TargetDrive)\"
$script:WindowsRoot = if ($env:windir) { $env:windir } else { Join-Path $script:TargetRoot "Windows" }
$script:IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
$script:SafetyBoundaries = @{}
$script:ScanResults = @()
$script:OperationRecords = New-Object System.Collections.Generic.List[string]
$script:CleanRecords = New-Object System.Collections.Generic.List[object]
$script:FailureRecords = New-Object System.Collections.Generic.List[object]

try { $host.UI.RawUI.WindowTitle = $script:AppName } catch {}

function Write-Ui {
    param(
        [string]$Text,
        [string]$Type = "Info",
        [switch]$NoNewline
    )

    $color = switch ($Type) {
        "Title" { "Cyan" }
        "Success" { "Green" }
        "Warn" { "Yellow" }
        "Risk" { "Red" }
        "Skip" { "DarkGray" }
        "Default" { "Cyan" }
        default { "White" }
    }

    if ($NoNewline) {
        Write-Host $Text -ForegroundColor $color -NoNewline
    } else {
        Write-Host $Text -ForegroundColor $color
    }
}

function Add-Log {
    param([string]$Text = "")
    $script:LogBuffer.Add($Text) | Out-Null
}

function Save-Log {
    if (-not $script:LogAvailable) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:LogDayFolder -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $script:LogDayFolder -Force -ErrorAction Stop | Out-Null
        }
        Set-Content -LiteralPath $script:LogPath -Value $script:LogBuffer -Encoding UTF8 -ErrorAction Stop
        Write-Ui "日志已生成：" "Success"
        Write-Ui $script:LogPath "Default"
    } catch {
        $script:LogAvailable = $false
        Write-Ui "日志文件夹创建或写入失败。请把脚本放到有写入权限的文件夹后重新运行。" "Risk"
        Write-Ui ("目标日志路径：{0}" -f $script:LogPath) "Warn"
        Write-Ui ("失败原因：{0}" -f $_.Exception.Message) "Warn"
    }
}

function Add-Operation {
    param([string]$Text)
    $script:OperationRecords.Add(("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text)) | Out-Null
    Add-Log ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text)
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -lt 0) { $Bytes = 0 }
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0:N0} B" -f $Bytes
}

function Get-PathSize {
    param(
        [string[]]$Paths,
        [int]$MaxSecondsPerPath = 8,
        [int]$MaxFilesPerPath = 20000
    )

    $total = 0L
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not $item.PSIsContainer) {
                $total += $item.Length
                continue
            }
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $count = 0
            try {
                Get-ChildItem -LiteralPath $path -Force -Recurse -File -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        if ($watch.Elapsed.TotalSeconds -ge $MaxSecondsPerPath -or $count -ge $MaxFilesPerPath) { throw "__SCAN_LIMIT__" }
                        $total += $_.Length
                        $count++
                    }
            } catch {
                if ($_.Exception.Message -ne "__SCAN_LIMIT__") { throw }
            }
        } catch {}
    }
    return [int64]$total
}

function Get-PathSizeFast {
    param([string[]]$Paths)

    $total = 0L
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not $item.PSIsContainer) {
                $total += $item.Length
                continue
            }
            Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                ForEach-Object {
                    $total += $_.Length
                }
        } catch {}
    }
    return [int64]$total
}

function Get-LargeFilesSize {
    param(
        [string[]]$Roots,
        [int64]$ThresholdBytes = 500MB,
        [string[]]$Extensions = @(),
        [int]$MaxSecondsPerRoot = 10,
        [int]$MaxFilesPerRoot = 50000
    )

    $files = New-Object System.Collections.Generic.List[object]
    $total = 0L
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue)) { continue }
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $seen = 0
            try {
                Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        if ($watch.Elapsed.TotalSeconds -ge $MaxSecondsPerRoot -or $seen -ge $MaxFilesPerRoot) { throw "__SCAN_LIMIT__" }
                        $seen++
                        if ($_.Length -ge $ThresholdBytes -and ($Extensions.Count -eq 0 -or $Extensions -contains $_.Extension.ToLowerInvariant())) {
                            $files.Add([pscustomobject]@{
                                Path = $_.FullName
                                Size = $_.Length
                            }) | Out-Null
                            $total += $_.Length
                        }
                    }
            } catch {
                if ($_.Exception.Message -ne "__SCAN_LIMIT__") { throw }
            }
        } catch {}
    }

    $files = @($files | Sort-Object Size -Descending | Select-Object -First 30)

    return [pscustomobject]@{
        Total = [int64]$total
        Files = $files
    }
}

function Get-FilteredPathSize {
    param(
        [string]$Path,
        [scriptblock]$Filter
    )

    $total = 0L
    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return [int64]0 }
    try {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and (& $Filter $_) } |
            ForEach-Object { $total += $_.Length }
    } catch {}
    return [int64]$total
}

function Get-OldSystemLogFiles {
    param(
        [string[]]$Paths,
        [int]$MaxSeconds = 8,
        [int]$MaxFiles = 5000
    )

    $result = New-Object System.Collections.Generic.List[object]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $count = 0
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
        try {
            Get-ChildItem -LiteralPath $path -Force -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($watch.Elapsed.TotalSeconds -ge $MaxSeconds -or $count -ge $MaxFiles) { throw "__SCAN_LIMIT__" }
                    if ($_.LastWriteTime -lt (Get-Date).AddDays(-14) -and ($_.Extension -in @(".log", ".etl", ".cab", ".old", ".bak"))) {
                        $result.Add($_) | Out-Null
                    }
                    $count++
                }
        } catch {
            if ($_.Exception.Message -eq "__SCAN_LIMIT__") { break }
        }
    }
    return @($result.ToArray())
}

function Get-CDriveInfo {
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($script:TargetDrive)'" -ErrorAction SilentlyContinue
    if (-not $drive) {
        return [pscustomobject]@{ Size = 0L; Free = 0L; Used = 0L; FreePercent = 0 }
    }

    $used = [int64]$drive.Size - [int64]$drive.FreeSpace
    $percent = if ($drive.Size -gt 0) { ([double]$drive.FreeSpace / [double]$drive.Size) * 100 } else { 0 }
    return [pscustomobject]@{
        Size = [int64]$drive.Size
        Free = [int64]$drive.FreeSpace
        Used = [int64]$used
        FreePercent = $percent
    }
}

function Show-CDriveInfo {
    $info = Get-CDriveInfo
    Write-Ui "当前 C 盘状态：" "Title"
    Write-Ui ("总容量：{0}" -f (Format-Size $info.Size))
    Write-Ui ("已用空间：{0}" -f (Format-Size $info.Used))
    $freeType = if ($info.FreePercent -lt 10) { "Risk" } elseif ($info.FreePercent -lt 20) { "Warn" } else { "Success" }
    Write-Ui ("剩余空间：{0} ({1:N1}%)" -f (Format-Size $info.Free), $info.FreePercent) $freeType
}

function Initialize-Log {
    Add-Log "========== C盘清理日志 =========="
    Add-Log ("运行时间：{0}" -f ($script:StartTime.ToString("yyyy-MM-dd HH:mm:ss")))
    Add-Log ("运行用户：{0}" -f [Environment]::UserName)
    Add-Log ("管理员权限：{0}" -f ($(if ($script:IsAdmin) { "是" } else { "否" })))
    Add-Log ""
}

function Get-SafetyBoundaryDefinitions {
    return @(
        [pscustomobject]@{ Id = 1; Name = "保护桌面"; Default = $true; Key = "ProtectDesktop"; Desc = "桌面不会作为自动清理候选。" }
        [pscustomobject]@{ Id = 2; Name = "保护下载目录"; Default = $false; Key = "ProtectDownloads"; Desc = "下载目录不会作为自动清理候选。" }
        [pscustomobject]@{ Id = 3; Name = "保护浏览器登录状态和 Cookie"; Default = $true; Key = "ProtectBrowserSessions"; Desc = "不清理 Cookie、登录状态和账号会话数据。" }
        [pscustomobject]@{ Id = 4; Name = "保护聊天软件数据"; Default = $true; Key = "ProtectChatData"; Desc = "不清理微信、QQ、企业微信等聊天资料目录。" }
        [pscustomobject]@{ Id = 5; Name = "保护开发环境缓存"; Default = $true; Key = "ProtectDevCache"; Desc = "不清理 npm、pip、Gradle、Maven、NuGet 等缓存。" }
        [pscustomobject]@{ Id = 6; Name = "保护系统还原和回滚能力"; Default = $true; Key = "ProtectRollback"; Desc = "不删除还原点、Windows.old，不主动破坏更新回滚能力。" }
        [pscustomobject]@{ Id = 7; Name = "保护游戏和图形软件缓存"; Default = $true; Key = "ProtectGraphicsCache"; Desc = "不清理显卡着色器、游戏和图形软件缓存。" }
        [pscustomobject]@{ Id = 8; Name = "保护大文件，只扫描不删除"; Default = $true; Key = "ProtectLargeFiles"; Desc = "大文件只进入报告，不自动删除。" }
    )
}

function Select-SafetyBoundaries {
    $defs = Get-SafetyBoundaryDefinitions
    while ($true) {
        Clear-Host
        Write-Ui "========== 安全边界 ==========" "Title"
        Write-Ui "【默认保护提示】直接按回车，将使用默认建议保护项。" "Default"
        Write-Ui "默认建议保护项已用青色标出。" "Default"
        Write-Host ""
        Write-Ui "请选择需要保护的内容："

        foreach ($def in $defs) {
            $line = "[{0}] {1}{2}" -f $def.Id, $def.Name, ($(if ($def.Default) { " （默认）" } else { "" }))
            if ($def.Default) { Write-Ui $line "Default" } else { Write-Ui $line }
        }
        Write-Ui "[0] 不额外保护"
        Write-Host ""
        Write-Ui "多个选项请用空格分隔，例如：1 3 4 7"
        Write-Ui "直接按回车：使用默认建议保护项" "Default"
        $inputText = Read-Host "请输入"

        if ([string]::IsNullOrWhiteSpace($inputText)) {
            $selectedIds = $defs | Where-Object { $_.Default } | Select-Object -ExpandProperty Id
        } elseif ($inputText.Trim() -eq "0") {
            $selectedIds = @()
        } else {
            $parts = $inputText.Trim() -split "\s+"
            $valid = $true
            $selectedIds = @()
            foreach ($part in $parts) {
                $num = 0
                if (-not [int]::TryParse($part, [ref]$num) -or $num -lt 1 -or $num -gt 8) {
                    $valid = $false
                    break
                }
                $selectedIds += $num
            }
            if (-not $valid) {
                Write-Ui "输入无效，请重新输入。" "Warn"
                Start-Sleep -Seconds 1
                continue
            }
            $selectedIds = $selectedIds | Select-Object -Unique
        }

        $script:SafetyBoundaries = @{}
        foreach ($def in $defs) {
            $script:SafetyBoundaries[$def.Key] = $selectedIds -contains $def.Id
        }

        Add-Log "========== 本次启用的安全边界 =========="
        foreach ($def in $defs) {
            if ($script:SafetyBoundaries[$def.Key]) {
                Add-Log ("[{0}] {1}" -f $def.Id, $def.Name)
                Add-Log ("说明：{0}" -f $def.Desc)
            }
        }
        Add-Log ""
        return
    }
}

function Test-Protected {
    param([string]$BoundaryKey)
    return ($script:SafetyBoundaries.ContainsKey($BoundaryKey) -and $script:SafetyBoundaries[$BoundaryKey])
}

function New-ScanItem {
    param(
        [int]$Id,
        [string]$Category,
        [string]$Name,
        [string[]]$Paths = @(),
        [int64]$EstimatedBytes = 0,
        [string]$Impact,
        [string]$Action,
        [bool]$AllowClean = $true,
        [bool]$RequiresAdmin = $false,
        [bool]$HighRisk = $false,
        [string]$BoundaryKey = "",
        [string]$BoundaryReason = "",
        [object[]]$Details = @()
    )

    $status = "可选择"
    $skipReason = ""
    if ($BoundaryKey -and (Test-Protected $BoundaryKey)) {
        $status = "已跳过"
        $skipReason = $BoundaryReason
        $AllowClean = $false
    } elseif (-not $AllowClean) {
        $status = "只扫描"
    } elseif ($RequiresAdmin -and -not $script:IsAdmin) {
        $status = "需要管理员权限"
        $skipReason = "当前不是管理员权限"
        $AllowClean = $false
    }

    return [pscustomobject]@{
        Id = $Id
        Category = $Category
        Name = $Name
        Paths = $Paths
        EstimatedBytes = [int64]$EstimatedBytes
        Impact = $Impact
        Action = $Action
        AllowClean = $AllowClean
        RequiresAdmin = $RequiresAdmin
        HighRisk = $HighRisk
        BoundaryKey = $BoundaryKey
        Status = $status
        SkipReason = $skipReason
        Details = $Details
    }
}

function Get-UserProfilePath {
    return [Environment]::GetFolderPath("UserProfile")
}

function Get-DownloadsPath {
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace("shell:Downloads")
        if ($folder -and $folder.Self -and $folder.Self.Path) {
            return $folder.Self.Path
        }
    } catch {}

    return (Join-Path (Get-UserProfilePath) "Downloads")
}

function Get-BrowserCachePaths {
    $local = [Environment]::GetFolderPath("LocalApplicationData")
    return @(
        Join-Path $local "Google\Chrome\User Data\Default\Cache"
        Join-Path $local "Google\Chrome\User Data\Default\Code Cache"
        Join-Path $local "Google\Chrome\User Data\Default\GPUCache"
        Join-Path $local "Microsoft\Edge\User Data\Default\Cache"
        Join-Path $local "Microsoft\Edge\User Data\Default\Code Cache"
        Join-Path $local "Microsoft\Edge\User Data\Default\GPUCache"
    )
}

function Get-ShaderCachePaths {
    $local = [Environment]::GetFolderPath("LocalApplicationData")
    return @(
        Join-Path $local "D3DSCache"
        Join-Path $local "NVIDIA\DXCache"
        Join-Path $local "NVIDIA\GLCache"
        Join-Path $local "AMD\DxCache"
        Join-Path $local "AMD\GLCache"
        (Join-Path $env:ProgramData "NVIDIA Corporation\NV_Cache")
    )
}

function Invoke-Scan {
    Write-Ui "正在扫描 C 盘可清理项目，只扫描不删除..." "Title"
    $script:ScanResults = @()
    $userProfile = Get-UserProfilePath
    $local = [Environment]::GetFolderPath("LocalApplicationData")
    $temp = $env:TEMP
    $desktop = [Environment]::GetFolderPath("Desktop")
    $downloads = Get-DownloadsPath
    $documentPath = [Environment]::GetFolderPath("MyDocuments")

    $script:ScanResults += New-ScanItem -Id 1 -Category "安全清理" -Name "用户临时目录" -Paths @($temp) -EstimatedBytes (Get-PathSize @($temp)) -Impact "通常无影响，正在使用的文件会跳过。" -Action "UserTemp"
    $windowsTempPath = Join-Path $script:WindowsRoot "Temp"
    $script:ScanResults += New-ScanItem -Id 2 -Category "安全清理" -Name "Windows 临时目录" -Paths @($windowsTempPath) -EstimatedBytes (Get-PathSize @($windowsTempPath)) -Impact "通常无影响，部分文件可能需要管理员权限。" -Action "WindowsTemp" -RequiresAdmin $true
    $thumbPaths = @((Join-Path $local "Microsoft\Windows\Explorer"))
    $thumbSize = Get-FilteredPathSize -Path $thumbPaths[0] -Filter { param($file) $file.Name -like "thumbcache_*.db" -or $file.Name -like "iconcache_*.db" }
    $script:ScanResults += New-ScanItem -Id 3 -Category "安全清理" -Name "缩略图缓存" -Paths $thumbPaths -EstimatedBytes $thumbSize -Impact "图片、视频文件不会丢失，但缩略图会重新生成。" -Action "Thumbnails"
    $werPaths = @(
        Join-Path $local "Microsoft\Windows\WER"
        (Join-Path $env:ProgramData "Microsoft\Windows\WER")
    )
    $script:ScanResults += New-ScanItem -Id 4 -Category "安全清理" -Name "Windows 错误报告缓存" -Paths $werPaths -EstimatedBytes (Get-PathSize $werPaths) -Impact "以后无法查看这些旧错误报告。" -Action "WerCache"

    $recyclePath = Join-Path $script:TargetRoot '$Recycle.Bin'
    $recycleSize = Get-PathSize @($recyclePath)
    $script:ScanResults += New-ScanItem -Id 1 -Category "常规清理" -Name "回收站" -Paths @($recyclePath) -EstimatedBytes $recycleSize -Impact "删除后无法从回收站恢复。" -Action "RecycleBin"
    $browserPaths = Get-BrowserCachePaths
    $script:ScanResults += New-ScanItem -Id 2 -Category "常规清理" -Name "浏览器普通缓存" -Paths $browserPaths -EstimatedBytes (Get-PathSize $browserPaths) -Impact "网页资源会重新加载，首次访问可能变慢；不会清理 Cookie 和登录状态。" -Action "BrowserCache"
    $wuPaths = @(Join-Path $script:WindowsRoot "SoftwareDistribution\Download")
    $script:ScanResults += New-ScanItem -Id 3 -Category "常规清理" -Name "Windows 更新下载缓存" -Paths $wuPaths -EstimatedBytes (Get-PathSize $wuPaths) -Impact "Windows Update 可能重新下载部分更新。" -Action "WindowsUpdateCache" -RequiresAdmin $true
    $doPaths = @(Join-Path $script:WindowsRoot "ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache")
    $script:ScanResults += New-ScanItem -Id 4 -Category "常规清理" -Name "Delivery Optimization 缓存" -Paths $doPaths -EstimatedBytes (Get-PathSize $doPaths) -Impact "通常无明显影响。" -Action "DeliveryOptimization" -RequiresAdmin $true
    $logPaths = @((Join-Path $script:WindowsRoot "Logs"), (Join-Path $script:WindowsRoot "System32\LogFiles"))
    $logSize = 0L
    foreach ($logFile in (Get-OldSystemLogFiles -Paths $logPaths)) { $logSize += $logFile.Length }
    $script:ScanResults += New-ScanItem -Id 5 -Category "常规清理" -Name "系统日志归档" -Paths $logPaths -EstimatedBytes $logSize -Impact "排查旧问题时可参考的信息减少。" -Action "SystemLogs" -RequiresAdmin $true
    $shaderPaths = Get-ShaderCachePaths
    $script:ScanResults += New-ScanItem -Id 6 -Category "常规清理" -Name "显卡着色器缓存" -Paths $shaderPaths -EstimatedBytes (Get-PathSize $shaderPaths) -Impact "游戏或图形软件首次启动、首次加载场景、首次编译材质时可能变慢。" -Action "ShaderCache" -BoundaryKey "ProtectGraphicsCache" -BoundaryReason "启用了 [7] 保护游戏和图形软件缓存"

    $winsxs = @(Join-Path $script:WindowsRoot "WinSxS")
    $script:ScanResults += New-ScanItem -Id 1 -Category "深度清理" -Name "Windows 旧组件缓存" -Paths $winsxs -EstimatedBytes 0 -Impact "将调用系统组件清理能力，可能影响部分更新卸载；预计释放空间由系统工具执行后确定。" -Action "ComponentCleanup" -RequiresAdmin $true -BoundaryKey "ProtectRollback" -BoundaryReason "启用了 [6] 保护系统还原和回滚能力"
    $driverPaths = @(Join-Path $script:WindowsRoot "System32\DriverStore\FileRepository")
    $script:ScanResults += New-ScanItem -Id 2 -Category "深度清理" -Name "旧驱动安装包缓存" -Paths $driverPaths -EstimatedBytes 0 -Impact "回滚旧驱动可能受影响；第一版只做位置提示，不递归统计驱动仓库以避免扫描过慢。" -Action "DriverStoreScan" -AllowClean $false
    $downloadLarge = Get-LargeFilesSize -Roots @($downloads) -ThresholdBytes 500MB
    $script:ScanResults += New-ScanItem -Id 3 -Category "深度清理" -Name "下载目录大文件" -Paths @($downloads) -EstimatedBytes $downloadLarge.Total -Impact "可能包含用户真实文件，默认只扫描提示。" -Action "DownloadsLargeFiles" -AllowClean $false -BoundaryKey "ProtectDownloads" -BoundaryReason "启用了 [2] 保护下载目录" -Details $downloadLarge.Files
    if (Test-Protected "ProtectDesktop") {
        $desktopLarge = [pscustomobject]@{ Total = 0L; Files = @() }
    } else {
        $desktopLarge = Get-LargeFilesSize -Roots @($desktop) -ThresholdBytes 500MB -MaxSecondsPerRoot 5
    }
    $script:ScanResults += New-ScanItem -Id 4 -Category "深度清理" -Name "桌面大文件" -Paths @($desktop) -EstimatedBytes $desktopLarge.Total -Impact "可能包含工作文件，默认只扫描提示。" -Action "DesktopLargeFiles" -AllowClean $false -BoundaryKey "ProtectDesktop" -BoundaryReason "启用了 [1] 保护桌面" -Details $desktopLarge.Files
    $softwareCachePaths = @(
        Join-Path $local "Adobe\Common\Media Cache"
        Join-Path $local "Temp"
        Join-Path $local "CrashDumps"
    )
    $script:ScanResults += New-ScanItem -Id 5 -Category "深度清理" -Name "软件缓存目录扫描" -Paths $softwareCachePaths -EstimatedBytes (Get-PathSize $softwareCachePaths) -Impact "可能影响软件首次打开速度，默认只列建议。" -Action "SoftwareCacheScan" -AllowClean $false
    $archiveExt = @(".exe", ".msi", ".zip", ".rar", ".7z", ".iso")
    $archiveRoots = @($downloads)
    if (-not (Test-Protected "ProtectDesktop")) { $archiveRoots += $desktop }
    $archiveScan = Get-LargeFilesSize -Roots $archiveRoots -ThresholdBytes 500MB -Extensions $archiveExt -MaxSecondsPerRoot 5
    $script:ScanResults += New-ScanItem -Id 6 -Category "深度清理" -Name "安装包和压缩包扫描" -Paths @($downloads, $desktop) -EstimatedBytes $archiveScan.Total -Impact "可能仍然有用，不能自动删除。" -Action "ArchiveScan" -AllowClean $false -BoundaryKey "ProtectLargeFiles" -BoundaryReason "启用了 [8] 保护大文件，只扫描不删除" -Details $archiveScan.Files
    $imageExt = @(".vhd", ".vhdx", ".qcow2", ".iso")
    $imageRoots = @($downloads, $documentPath)
    if (-not (Test-Protected "ProtectDesktop")) { $imageRoots += $desktop }
    $imageRoots = $imageRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue) }
    $imageScan = Get-LargeFilesSize -Roots $imageRoots -ThresholdBytes 500MB -Extensions $imageExt -MaxSecondsPerRoot 5
    $script:ScanResults += New-ScanItem -Id 7 -Category "深度清理" -Name "虚拟机/镜像大文件扫描" -Paths $imageRoots -EstimatedBytes $imageScan.Total -Impact "可能是真实系统或项目数据，只扫描，禁止自动删除；第一版只扫描下载、桌面和文档目录。" -Action "VmImageScan" -AllowClean $false -BoundaryKey "ProtectLargeFiles" -BoundaryReason "启用了 [8] 保护大文件，只扫描不删除" -Details $imageScan.Files

    $hiber = Join-Path $script:TargetRoot "hiberfil.sys"
    $script:ScanResults += New-ScanItem -Id 1 -Category "高风险清理" -Name "删除休眠文件" -Paths @($hiber) -EstimatedBytes (Get-PathSize @($hiber)) -Impact "不能使用休眠，快速启动可能受影响。" -Action "DisableHibernate" -RequiresAdmin $true -HighRisk $true
    $restoreSize = 0L
    if (-not (Test-Protected "ProtectRollback")) {
        try {
            $shadowText = vssadmin list shadowstorage /for=$($script:TargetDrive) 2>$null | Out-String
            if ($shadowText -match "Used Shadow Copy Storage space:\s*([\d\.,]+)\s*(KB|MB|GB|TB)") {
                $num = [double](($matches[1]) -replace ",", "")
                $unit = $matches[2]
                $restoreSize = switch ($unit) {
                    "KB" { [int64]($num * 1KB) }
                    "MB" { [int64]($num * 1MB) }
                    "GB" { [int64]($num * 1GB) }
                    "TB" { [int64]($num * 1TB) }
                }
            }
        } catch {}
    }
    $script:ScanResults += New-ScanItem -Id 2 -Category "高风险清理" -Name "删除系统还原点" -Paths @("System Volume Information") -EstimatedBytes $restoreSize -Impact "无法回滚到之前状态。" -Action "RestorePoints" -RequiresAdmin $true -HighRisk $true -BoundaryKey "ProtectRollback" -BoundaryReason "启用了 [6] 保护系统还原和回滚能力"
    $windowsOld = @(Join-Path $script:TargetRoot "Windows.old")
    $script:ScanResults += New-ScanItem -Id 3 -Category "高风险清理" -Name "删除 Windows.old" -Paths $windowsOld -EstimatedBytes (Get-PathSize $windowsOld) -Impact "无法回退到升级前系统。" -Action "WindowsOld" -RequiresAdmin $true -HighRisk $true -BoundaryKey "ProtectRollback" -BoundaryReason "启用了 [6] 保护系统还原和回滚能力"
    $cookiePaths = @(
        Join-Path $local "Google\Chrome\User Data\Default\Network\Cookies"
        Join-Path $local "Microsoft\Edge\User Data\Default\Network\Cookies"
    )
    $cookieSize = if (Test-Protected "ProtectBrowserSessions") { 0L } else { Get-PathSize $cookiePaths }
    $script:ScanResults += New-ScanItem -Id 4 -Category "高风险清理" -Name "清理浏览器 Cookie/登录状态" -Paths $cookiePaths -EstimatedBytes $cookieSize -Impact "网站需要重新登录，部分网页偏好设置可能丢失。" -Action "BrowserSessions" -HighRisk $true -BoundaryKey "ProtectBrowserSessions" -BoundaryReason "启用了 [3] 保护浏览器登录状态和 Cookie"
    $chatPaths = @(
        Join-Path $documentPath "WeChat Files"
        Join-Path $documentPath "Tencent Files"
        Join-Path $documentPath "WXWork"
    )
    $chatSize = if (Test-Protected "ProtectChatData") { 0L } else { Get-PathSize $chatPaths -MaxSecondsPerPath 5 }
    $script:ScanResults += New-ScanItem -Id 5 -Category "高风险清理" -Name "清理聊天软件缓存" -Paths $chatPaths -EstimatedBytes $chatSize -Impact "旧图片、视频、文件可能无法查看。" -Action "ChatCache" -HighRisk $true -BoundaryKey "ProtectChatData" -BoundaryReason "启用了 [4] 保护聊天软件数据"
    $devPaths = @(
        Join-Path $userProfile ".npm"
        Join-Path $userProfile ".cache\pip"
        Join-Path $userProfile ".gradle\caches"
        Join-Path $userProfile ".nuget\packages"
        Join-Path $userProfile ".cargo\registry"
    )
    $devSize = if (Test-Protected "ProtectDevCache") { 0L } else { Get-PathSize $devPaths -MaxSecondsPerPath 5 }
    $script:ScanResults += New-ScanItem -Id 6 -Category "高风险清理" -Name "清理开发环境缓存" -Paths $devPaths -EstimatedBytes $devSize -Impact "依赖需重新下载，首次构建变慢，离线开发可能受影响。" -Action "DevCache" -HighRisk $true -BoundaryKey "ProtectDevCache" -BoundaryReason "启用了 [5] 保护开发环境缓存"
    $graphicsHighPaths = @(
        (Get-ShaderCachePaths)
        (Join-Path $local "Adobe\Common\Media Cache")
        (Join-Path $local "Blender Foundation\Blender")
    ) | ForEach-Object { $_ }
    $graphicsHighSize = if (Test-Protected "ProtectGraphicsCache") { 0L } else { Get-PathSize $graphicsHighPaths -MaxSecondsPerPath 5 }
    $script:ScanResults += New-ScanItem -Id 7 -Category "高风险清理" -Name "清理游戏/图形软件缓存" -Paths $graphicsHighPaths -EstimatedBytes $graphicsHighSize -Impact "游戏和图形软件首次加载变慢，部分预览缓存需要重新生成。" -Action "GraphicsAppCache" -HighRisk $true -BoundaryKey "ProtectGraphicsCache" -BoundaryReason "启用了 [7] 保护游戏和图形软件缓存"

    Write-ScanLog
    Write-Ui "扫描完成。日志内容已暂存，主动退出脚本时会生成日志文件。" "Success"
}

function Write-ScanLog {
    $info = Get-CDriveInfo
    Add-Log "========== C盘状态 =========="
    Add-Log ("总容量：{0}" -f (Format-Size $info.Size))
    Add-Log ("已用空间：{0}" -f (Format-Size $info.Used))
    Add-Log ("剩余空间：{0}" -f (Format-Size $info.Free))
    Add-Log ("剩余比例：{0:N1}%" -f $info.FreePercent)
    Add-Log ""
    Add-Log "========== 扫描结果概览 =========="
    foreach ($category in @("安全清理", "常规清理", "深度清理", "高风险清理")) {
        $sum = ($script:ScanResults | Where-Object { $_.Category -eq $category } | Measure-Object -Property EstimatedBytes -Sum).Sum
        Add-Log ("{0}：预计可释放 {1}" -f $category, (Format-Size $sum))
    }
    Add-Log ""
    Add-Log "========== 扫描详情 =========="
    foreach ($category in @("安全清理", "常规清理", "深度清理", "高风险清理")) {
        Add-Log ("[{0}]" -f $category)
        foreach ($item in ($script:ScanResults | Where-Object { $_.Category -eq $category } | Sort-Object Id)) {
            Add-Log ("- [{0}] {1}" -f $item.Id, $item.Name)
            Add-Log ("  路径：{0}" -f ($(if ($item.Paths.Count -gt 0) { $item.Paths -join "；" } else { "无" })))
            Add-Log ("  预计可释放：{0}" -f (Format-Size $item.EstimatedBytes))
            Add-Log ("  状态：{0}" -f $item.Status)
            if ($item.SkipReason) { Add-Log ("  跳过原因：{0}" -f $item.SkipReason) }
            Add-Log ("  影响：{0}" -f $item.Impact)
            if ($item.Details -and $item.Details.Count -gt 0) {
                Add-Log "  发现的大文件（最多记录 30 个）："
                foreach ($detail in $item.Details) {
                    Add-Log ("    - {0} ({1})" -f $detail.Path, (Format-Size $detail.Size))
                }
            }
        }
        Add-Log ""
    }
}

function Show-ScanSummary {
    Clear-Host
    Write-Ui "========== C盘清理扫描报告 ==========" "Title"
    Show-CDriveInfo
    Write-Host ""
    Write-Ui "本次启用的安全边界：" "Title"
    $defs = Get-SafetyBoundaryDefinitions
    foreach ($def in $defs) {
        if ($script:SafetyBoundaries[$def.Key]) {
            Write-Ui ("[{0}] {1}" -f $def.Id, $def.Name) "Default"
        }
    }
    Write-Host ""
    Write-Ui "可清理项目概览：" "Title"
    foreach ($category in @("安全清理", "常规清理", "深度清理", "高风险清理")) {
        $sum = ($script:ScanResults | Where-Object { $_.Category -eq $category } | Measure-Object -Property EstimatedBytes -Sum).Sum
        $type = switch ($category) {
            "安全清理" { "Success" }
            "常规清理" { "Warn" }
            "深度清理" { "Warn" }
            "高风险清理" { "Risk" }
        }
        Write-Ui ("[{0}] 预计可释放：{1}" -f $category, (Format-Size $sum)) $type
    }
    Write-Host ""
    $skipped = $script:ScanResults | Where-Object { $_.Status -eq "已跳过" }
    if ($skipped.Count -gt 0) {
        Write-Ui "因安全边界跳过：" "Skip"
        foreach ($item in $skipped) {
            Write-Ui ("- {0}：{1}" -f $item.Name, $item.SkipReason) "Skip"
        }
    }
}

function Show-CategoryDetails {
    param([string]$Category)

    Clear-Host
    $type = switch ($Category) {
        "安全清理" { "Success" }
        "常规清理" { "Warn" }
        "深度清理" { "Warn" }
        "高风险清理" { "Risk" }
        default { "Title" }
    }
    Write-Ui ("========== {0} ==========" -f $Category) $type
    $items = $script:ScanResults | Where-Object { $_.Category -eq $Category } | Sort-Object Id
    foreach ($item in $items) {
        $lineType = if ($item.Status -eq "已跳过" -or $item.Status -eq "只扫描" -or $item.Status -eq "需要管理员权限") { "Skip" } elseif ($item.HighRisk) { "Risk" } else { $type }
        Write-Ui ("[{0}] {1}" -f $item.Id, $item.Name) $lineType
        Write-Ui ("预计可释放：{0}" -f (Format-Size $item.EstimatedBytes))
        Write-Ui ("影响：{0}" -f $item.Impact)
        Write-Ui ("状态：{0}" -f $item.Status) $lineType
        if ($item.SkipReason) { Write-Ui ("原因：{0}" -f $item.SkipReason) "Skip" }
        if ($item.Details -and $item.Details.Count -gt 0) {
            Write-Ui "发现的大文件（最多显示 10 个）：" "Warn"
            foreach ($detail in ($item.Details | Select-Object -First 10)) {
                Write-Ui ("- {0} ({1})" -f $detail.Path, (Format-Size $detail.Size)) "Skip"
            }
        }
        Write-Host ""
    }
}

function Parse-Selection {
    param(
        [string]$InputText,
        [object[]]$Items
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) { return @() }
    $trim = $InputText.Trim()
    if ($trim -eq "0") { return $null }
    if ($trim.ToLowerInvariant() -eq "all") {
        return @($Items | Where-Object { $_.AllowClean -and $_.Status -eq "可选择" })
    }

    $parts = $trim -split "\s+"
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($part in $parts) {
        $num = 0
        if (-not [int]::TryParse($part, [ref]$num)) {
            Write-Ui "输入无效，请使用编号、空格、all 或 0。" "Warn"
            return @()
        }
        $item = $Items | Where-Object { $_.Id -eq $num } | Select-Object -First 1
        if (-not $item) {
            Write-Ui ("编号 {0} 不存在。" -f $num) "Warn"
            return @()
        }
        if (-not $item.AllowClean -or $item.Status -ne "可选择") {
            Write-Ui ("[{0}] {1} 当前状态为 [{2}]，不能选择。" -f $item.Id, $item.Name, $item.Status) "Warn"
            if ($item.SkipReason) { Write-Ui ("原因：{0}" -f $item.SkipReason) "Skip" }
            return @()
        }
        if (-not ($selected | Where-Object { $_.Id -eq $item.Id })) {
            $selected.Add($item) | Out-Null
        }
    }
    return @($selected.ToArray())
}

function Confirm-NormalItems {
    param([object[]]$Items)

    Write-Ui "你本次选择了以下项目：" "Title"
    foreach ($item in $Items) {
        Write-Ui ("[{0}] {1}" -f $item.Id, $item.Name)
        Write-Ui ("预计释放：{0}" -f (Format-Size $item.EstimatedBytes))
        Write-Ui ("影响：{0}" -f $item.Impact)
        Write-Host ""
    }
    $sum = ($Items | Measure-Object -Property EstimatedBytes -Sum).Sum
    Write-Ui ("预计合计释放：{0}" -f (Format-Size $sum)) "Warn"
    $confirm = Read-Host "确认执行清理吗？输入 Y 执行，输入其他内容取消"
    return ($confirm -eq "Y" -or $confirm -eq "y")
}

function Confirm-HighRiskItem {
    param([object]$Item)

    Write-Ui ("你选择了：{0}" -f $Item.Name) "Risk"
    Write-Ui "风险说明：" "Risk"
    Write-Ui $Item.Impact "Risk"
    Write-Ui ("预计释放：{0}" -f (Format-Size $Item.EstimatedBytes)) "Warn"
    $confirm = Read-Host "如确认执行，请输入大写 YES"
    return ($confirm -ceq "YES")
}

function Remove-PathContents {
    param([string[]]$Paths)

    $freed = 0L
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
        try {
            $before = Get-PathSize @($path)
            $children = Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue
            foreach ($child in $children) {
                try {
                    Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
                } catch {
                    $script:FailureRecords.Add([pscustomobject]@{ Path = $child.FullName; Reason = $_.Exception.Message }) | Out-Null
                }
            }
            $after = Get-PathSize @($path)
            $freed += [Math]::Max(0, $before - $after)
        } catch {
            $script:FailureRecords.Add([pscustomobject]@{ Path = $path; Reason = $_.Exception.Message }) | Out-Null
        }
    }
    return [int64]$freed
}

function Remove-PathItself {
    param([string[]]$Paths)

    $freed = 0L
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
        try {
            $before = Get-PathSize @($path)
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $freed += $before
        } catch {
            $script:FailureRecords.Add([pscustomobject]@{ Path = $path; Reason = $_.Exception.Message }) | Out-Null
        }
    }
    return [int64]$freed
}

function Invoke-CleanItem {
    param([object]$Item)

    $freed = 0L
    try {
        switch ($Item.Action) {
            "UserTemp" { $freed = Remove-PathContents $Item.Paths }
            "WindowsTemp" { $freed = Remove-PathContents $Item.Paths }
            "Thumbnails" {
                $files = Get-ChildItem -LiteralPath $Item.Paths[0] -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "thumbcache_*.db" -or $_.Name -like "iconcache_*.db" }
                $before = ($files | Measure-Object -Property Length -Sum).Sum
                foreach ($file in $files) {
                    try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch {
                        $script:FailureRecords.Add([pscustomobject]@{ Path = $file.FullName; Reason = $_.Exception.Message }) | Out-Null
                    }
                }
                $freed = [int64]$before
            }
            "WerCache" { $freed = Remove-PathContents $Item.Paths }
            "RecycleBin" {
                $before = Get-PathSize $Item.Paths
                try {
                    Clear-RecycleBin -DriveLetter $script:TargetDriveLetter -Force -ErrorAction Stop
                    $after = Get-PathSize $Item.Paths
                    $freed = [Math]::Max(0, $before - $after)
                } catch {
                    $script:FailureRecords.Add([pscustomobject]@{ Path = (Join-Path $script:TargetRoot '$Recycle.Bin'); Reason = $_.Exception.Message }) | Out-Null
                }
            }
            "BrowserCache" { $freed = Remove-PathContents $Item.Paths }
            "WindowsUpdateCache" {
                try { Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue } catch {}
                $freed = Remove-PathContents $Item.Paths
                try { Start-Service -Name wuauserv -ErrorAction SilentlyContinue } catch {}
            }
            "DeliveryOptimization" {
                try { Stop-Service -Name DoSvc -Force -ErrorAction SilentlyContinue } catch {}
                $freed = Remove-PathContents $Item.Paths
                try { Start-Service -Name DoSvc -ErrorAction SilentlyContinue } catch {}
            }
            "SystemLogs" {
                $files = Get-OldSystemLogFiles -Paths $Item.Paths -MaxSeconds 15 -MaxFiles 10000
                foreach ($file in $files) {
                    try {
                        $len = $file.Length
                        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                        $freed += $len
                    } catch {
                        $script:FailureRecords.Add([pscustomobject]@{ Path = $file.FullName; Reason = $_.Exception.Message }) | Out-Null
                    }
                }
            }
            "ShaderCache" { $freed = Remove-PathContents $Item.Paths }
            "ComponentCleanup" {
                $before = (Get-CDriveInfo).Free
                $proc = Start-Process -FilePath "dism.exe" -ArgumentList "/Online", "/Cleanup-Image", "/StartComponentCleanup" -Wait -PassThru -WindowStyle Hidden
                if ($proc.ExitCode -ne 0) {
                    $script:FailureRecords.Add([pscustomobject]@{ Path = "DISM StartComponentCleanup"; Reason = "dism.exe 退出码：$($proc.ExitCode)" }) | Out-Null
                }
                $after = (Get-CDriveInfo).Free
                $freed = [Math]::Max(0, $after - $before)
            }
            "DisableHibernate" {
                $before = (Get-CDriveInfo).Free
                $proc = Start-Process -FilePath "powercfg.exe" -ArgumentList "/hibernate", "off" -Wait -PassThru -WindowStyle Hidden
                if ($proc.ExitCode -ne 0) {
                    $script:FailureRecords.Add([pscustomobject]@{ Path = (Join-Path $script:TargetRoot "hiberfil.sys"); Reason = "powercfg.exe 退出码：$($proc.ExitCode)" }) | Out-Null
                }
                $after = (Get-CDriveInfo).Free
                $freed = [Math]::Max(0, $after - $before)
            }
            "RestorePoints" {
                $before = (Get-CDriveInfo).Free
                $proc = Start-Process -FilePath "vssadmin.exe" -ArgumentList "delete", "shadows", "/for=$($script:TargetDrive)", "/all", "/quiet" -Wait -PassThru -WindowStyle Hidden
                if ($proc.ExitCode -ne 0) {
                    $script:FailureRecords.Add([pscustomobject]@{ Path = "系统还原点"; Reason = "vssadmin.exe 退出码：$($proc.ExitCode)" }) | Out-Null
                }
                $after = (Get-CDriveInfo).Free
                $freed = [Math]::Max(0, $after - $before)
            }
            "WindowsOld" { $freed = Remove-PathItself $Item.Paths }
            "BrowserSessions" { $freed = Remove-PathItself $Item.Paths }
            "ChatCache" { $freed = Remove-PathContents $Item.Paths }
            "DevCache" { $freed = Remove-PathContents $Item.Paths }
            "GraphicsAppCache" { $freed = Remove-PathContents $Item.Paths }
            default {
                $script:FailureRecords.Add([pscustomobject]@{ Path = $Item.Name; Reason = "未实现的清理动作：$($Item.Action)" }) | Out-Null
            }
        }
    } catch {
        $script:FailureRecords.Add([pscustomobject]@{ Path = $Item.Name; Reason = $_.Exception.Message }) | Out-Null
    }

    $script:CleanRecords.Add([pscustomobject]@{
        Time = Get-Date
        Category = $Item.Category
        Name = $Item.Name
        FreedBytes = [int64]$freed
    }) | Out-Null
    return [int64]$freed
}

function Invoke-CleanItems {
    param([object[]]$Items)

    $before = Get-CDriveInfo
    $cleanStartIndex = $script:CleanRecords.Count
    $failureStartIndex = $script:FailureRecords.Count
    $totalFreed = 0L
    foreach ($item in $Items) {
        Write-Ui ("正在清理：{0}" -f $item.Name) "Title"
        Add-Operation ("执行清理：{0} / {1}" -f $item.Category, $item.Name)
        $freed = Invoke-CleanItem $item
        $totalFreed += $freed
        Write-Ui ("完成：{0}，估算释放 {1}" -f $item.Name, (Format-Size $freed)) "Success"
    }
    $after = Get-CDriveInfo
    Write-Host ""
    Write-Ui "清理完成。" "Success"
    Write-Ui ("清理前剩余空间：{0}" -f (Format-Size $before.Free))
    Write-Ui ("清理后剩余空间：{0}" -f (Format-Size $after.Free))
    Write-Ui ("本次实际增加：{0}" -f (Format-Size ([Math]::Max(0, $after.Free - $before.Free)))) "Success"
    Write-Ui ("项目内估算释放：{0}" -f (Format-Size $totalFreed))
    $newFailureCount = $script:FailureRecords.Count - $failureStartIndex
    Write-Ui ("本次失败数量：{0}" -f $newFailureCount) $(if ($newFailureCount -gt 0) { "Warn" } else { "Success" })
    Write-CleanLog -CleanStartIndex $cleanStartIndex -FailureStartIndex $failureStartIndex
}

function Write-CleanLog {
    param(
        [int]$CleanStartIndex = 0,
        [int]$FailureStartIndex = 0
    )

    Add-Log "========== 用户选择记录 / 清理执行结果 =========="
    foreach ($record in ($script:CleanRecords | Select-Object -Skip $CleanStartIndex)) {
        Add-Log ("- {0} [{1}] {2}：{3}" -f $record.Time.ToString("HH:mm:ss"), $record.Category, $record.Name, (Format-Size $record.FreedBytes))
    }
    $newFailures = @($script:FailureRecords | Select-Object -Skip $FailureStartIndex)
    if ($newFailures.Count -gt 0) {
        Add-Log ""
        Add-Log "删除失败："
        foreach ($failure in ($newFailures | Select-Object -First 100)) {
            Add-Log ("- {0}" -f $failure.Path)
            Add-Log ("  原因：{0}" -f $failure.Reason)
        }
        if ($newFailures.Count -gt 100) {
            Add-Log "失败项超过 100 条，仅记录前 100 条。"
        }
    }
    Add-Log ""
}

function Show-CategoryMenu {
    param([string]$Category)

    while ($true) {
        Show-CategoryDetails $Category
        if ($Category -eq "高风险清理") {
            Write-Ui "请输入要处理的高风险项目编号；输入 0 返回上一级。" "Risk"
        } else {
            Write-Ui "请输入要清理的项目编号，多个项目用空格分隔，例如：1 3"
            Write-Ui "输入 all 选择当前分类全部可清理项目"
            Write-Ui "输入 0 返回上一级"
        }

        $inputText = Read-Host "请输入"
        $items = @($script:ScanResults | Where-Object { $_.Category -eq $Category } | Sort-Object Id)
        $selectionResult = Parse-Selection -InputText $inputText -Items $items
        if ($null -eq $selectionResult) { return }
        $selected = @($selectionResult)
        if ($selected.Count -eq 0) {
            Start-Sleep -Seconds 1
            continue
        }

        if ($Category -eq "高风险清理") {
            foreach ($item in $selected) {
                if (Confirm-HighRiskItem $item) {
                    Invoke-CleanItems @($item)
                } else {
                    Write-Ui "已取消。" "Warn"
                    Add-Operation ("取消高风险项目：{0}" -f $item.Name)
                }
                Write-Ui "按回车返回高风险菜单..."
                [void](Read-Host)
            }
        } else {
            if (Confirm-NormalItems $selected) {
                Invoke-CleanItems $selected
                Write-Ui "按回车返回主菜单..."
                [void](Read-Host)
                return
            } else {
                Write-Ui "已取消。" "Warn"
                Add-Operation ("取消清理分类：{0}" -f $Category)
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Ui "========== C盘清理助手 ==========" "Title"
        Show-CDriveInfo
        Write-Host ""
        Write-Ui "请选择清理分类：" "Title"
        Write-Ui "[1] 安全清理" "Success"
        Write-Ui "[2] 常规清理" "Warn"
        Write-Ui "[3] 深度清理" "Warn"
        Write-Ui "[4] 高风险清理" "Risk"
        Write-Ui "[9] 重新扫描"
        Write-Ui "[0] 退出"
        Write-Host ""
        $choice = Read-Host "请输入数字后按回车"

        switch ($choice) {
            "1" { Show-CategoryMenu "安全清理" }
            "2" { Show-CategoryMenu "常规清理" }
            "3" { Show-CategoryMenu "深度清理" }
            "4" { Show-CategoryMenu "高风险清理" }
            "9" {
                Add-Operation "用户选择重新扫描"
                Invoke-Scan
                Show-ScanSummary
                Write-Ui "按回车返回主菜单..."
                [void](Read-Host)
            }
            "0" {
                Add-Log "========== 结束 =========="
                Add-Log ("结束时间：{0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
                Save-Log
                Write-Ui "已退出。" "Success"
                return
            }
            default {
                Write-Ui "输入无效，请重新输入。" "Warn"
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Start-App {
    Initialize-Log
    if ($SmokeTest) {
        $defs = Get-SafetyBoundaryDefinitions
        $script:SafetyBoundaries = @{}
        foreach ($def in $defs) {
            $script:SafetyBoundaries[$def.Key] = $def.Default
        }
        Add-Operation "SmokeTest：使用默认安全边界执行扫描，不执行清理"
        Invoke-Scan
        Add-Log "========== 结束 =========="
        Add-Log ("结束时间：{0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
        Save-Log
        return
    }

    Clear-Host
    Write-Ui "========== C盘清理助手 ==========" "Title"
    Write-Ui "本工具会先扫描，不会在未确认前删除任何内容。"
    if (-not $script:IsAdmin) {
        Write-Ui "当前不是管理员权限，部分系统清理项可能只能扫描或无法清理。" "Warn"
    } else {
        Write-Ui "当前为管理员权限。" "Success"
    }
    Write-Host ""
    Show-CDriveInfo
    Write-Host ""
    Write-Ui "按回车继续选择安全边界..."
    [void](Read-Host)

    Select-SafetyBoundaries
    Invoke-Scan
    Show-ScanSummary
    Write-Ui "按回车进入主菜单..."
    [void](Read-Host)
    Show-MainMenu
}

Start-App
