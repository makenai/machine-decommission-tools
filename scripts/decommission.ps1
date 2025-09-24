# Machine Decommission Tool for Windows
# Requires: rclone installed and in PATH
# Run as Administrator for best results

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

Write-Host "=== Machine Decommission Tool for Windows ===" -ForegroundColor Cyan
Write-Host "This tool will capture machine info and backup user data" -ForegroundColor Yellow
Write-Host ""

if (-not $isAdmin) {
    Write-Host "Warning: Not running as Administrator. Some features may be limited." -ForegroundColor Yellow
    Write-Host "For best results, run PowerShell as Administrator" -ForegroundColor Yellow
    Write-Host ""
}

# Check if rclone is installed
try {
    $null = rclone version 2>$null
} catch {
    Write-Host "Error: rclone is not installed or not in PATH" -ForegroundColor Red
    Write-Host "Please install from https://rclone.org/downloads/" -ForegroundColor Red
    exit 1
}

Write-Host "✓ rclone is installed" -ForegroundColor Green

# Collect machine information
Write-Host ""
Write-Host "Collecting machine information..." -ForegroundColor Yellow

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$machineInfoFile = "$env:USERPROFILE\machine-info-$timestamp.json"

# Gather system info
$bios = Get-CimInstance Win32_BIOS
$system = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$network = Get-NetAdapter | Where-Object {$_.Status -eq 'Up'}

# Get list of user directories
$userDirs = Get-ChildItem "C:\Users" -Directory | Where-Object {
    $_.Name -notin @('Public', 'Default', 'All Users', 'Default User')
}

$machineInfo = @{
    metadata = @{
        timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        decommission_tool_version = "1.0-ps"
        decommissioned_by = $env:USERNAME
        decommission_reason = "manual"
    }
    system = @{
        hostname = $env:COMPUTERNAME
        os_type = "Windows"
        os_version = $os.Caption
        os_build = $os.BuildNumber
        boot_volume = $os.SystemDrive
        encryption_status = if ((Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue).ProtectionStatus -eq 'On') { 'Encrypted' } else { 'Not Encrypted' }
    }
    hardware = @{
        serial_number = $bios.SerialNumber
        hardware_uuid = (Get-CimInstance Win32_ComputerSystemProduct).UUID
        manufacturer = $system.Manufacturer
        model = $system.Model
        cpu = $cpu.Name
        cpu_cores = $cpu.NumberOfCores
        memory = [math]::Round($system.TotalPhysicalMemory / 1GB, 2).ToString() + " GB"
        firmware_version = $bios.SMBIOSBIOSVersion
    }
    storage = @{
        total_capacity = [math]::Round($disk.Size / 1GB, 2).ToString() + " GB"
        used_space = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2).ToString() + " GB"
        free_space = [math]::Round($disk.FreeSpace / 1GB, 2).ToString() + " GB"
    }
    network = @{
        mac_addresses = @($network | ForEach-Object { $_.MacAddress })
    }
    users = @{
        current_user = $env:USERNAME
        all_system_users = @($userDirs | ForEach-Object { $_.Name })
        total_users = $userDirs.Count
    }
}

$machineInfo | ConvertTo-Json -Depth 10 | Out-File -FilePath $machineInfoFile -Encoding UTF8
Write-Host "✓ Machine information saved to: $machineInfoFile" -ForegroundColor Green

# Display summary
Write-Host ""
Write-Host "Machine Summary:" -ForegroundColor Cyan
Write-Host "  Model: $($system.Model)"
Write-Host "  Serial: $($bios.SerialNumber)"
Write-Host "  OS: Windows $($os.Caption)"
Write-Host "  Storage: $([math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2)) GB used of $([math]::Round($disk.Size / 1GB, 2)) GB"
Write-Host "  Users: $($userDirs.Count) total"

# Setup B2 credentials
Write-Host ""
Write-Host "B2 Configuration" -ForegroundColor Yellow

# Check environment variables first
$keyId = $env:B2_APPLICATION_KEY_ID
$appKey = $env:B2_APPLICATION_KEY
$bucketName = $env:B2_BUCKET_NAME

if (-not $keyId) {
    $keyId = Read-Host "Enter your B2 Application Key ID"
}
if (-not $appKey) {
    $secureKey = Read-Host "Enter your B2 Application Key" -AsSecureString
    $appKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey))
}
if (-not $bucketName) {
    $bucketName = Read-Host "Enter your B2 bucket name"
}

# Configure rclone
Write-Host ""
Write-Host "Configuring rclone..." -ForegroundColor Yellow

$remoteName = "backup-remote"

# Check if remote exists
$remotes = rclone listremotes 2>$null
if ($remotes -notcontains "${remoteName}:") {
    # Create remote
    rclone config create $remoteName b2 account $keyId key $appKey hard_delete true 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Created remote '$remoteName'" -ForegroundColor Green
    } else {
        Write-Host "Error creating remote" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "✓ Remote '$remoteName' already configured" -ForegroundColor Green
}

# Test connection
Write-Host "Testing B2 connection..." -ForegroundColor Yellow
rclone lsd "${remoteName}:" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ Successfully connected to B2" -ForegroundColor Green
} else {
    Write-Host "Error: Could not connect to B2" -ForegroundColor Red
    exit 1
}

# Check if bucket exists
$buckets = rclone lsd "${remoteName}:" 2>$null
if ($buckets -notmatch $bucketName) {
    Write-Host "Creating bucket '$bucketName'..." -ForegroundColor Yellow
    rclone mkdir "${remoteName}:${bucketName}" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Created bucket '$bucketName'" -ForegroundColor Green
    }
}

# No subfolder - backup directly to bucket root
Write-Host ""
Write-Host "Backing up to: $bucketName (root)" -ForegroundColor Cyan

# Create excludes file
$excludesFile = "$env:TEMP\backup-excludes.txt"
@'
# Caches and temporary files
*\AppData\Local\Temp\**
*\AppData\Local\Microsoft\Windows\INetCache\**
*\AppData\Local\Microsoft\Windows\Temporary Internet Files\**
*\AppData\Local\Google\Chrome\User Data\**\Cache\**
*\AppData\Local\Mozilla\Firefox\Profiles\**\cache2\**
*\AppData\Local\Packages\**\AC\Temp\**
*\AppData\Local\Packages\**\LocalCache\**
*\AppData\Roaming\Code\Cache\**
*\AppData\Roaming\Code\CachedData\**
*\.cache\**
*\node_modules\**
*\.npm\**
*\.nuget\**

# System files
desktop.ini
Thumbs.db
*.tmp
*.temp
*.log
pagefile.sys
hiberfil.sys
swapfile.sys

# Large files
*.iso
*.vmdk
*.vdi
*.box
*.ova

# Build artifacts
*\bin\Debug\**
*\bin\Release\**
*\obj\Debug\**
*\obj\Release\**
*\target\**
*\build\**
*\dist\**

# Version control
*\.git\objects\**
*\.git\lfs\**
*\.svn\**
*\.hg\**

# Virtual machines
*\VirtualBox VMs\**
*\.vagrant\**

# Backup files
*.bak
*.backup
*~
*.swp
*.swo

# Windows specific
*\$RECYCLE.BIN\**
*\System Volume Information\**
*\Recovery\**
*\ProgramData\Microsoft\Windows\WER\**
*\Windows\**
*\Windows.old\**
'@ | Out-File -FilePath $excludesFile -Encoding UTF8

Write-Host "✓ Created excludes file" -ForegroundColor Green

# Backup each user
Write-Host ""
Write-Host "Starting backups..." -ForegroundColor Yellow
Write-Host "This may take a while depending on data size and connection speed" -ForegroundColor Yellow

$failedUsers = @()

foreach ($userDir in $userDirs) {
    $username = $userDir.Name
    $userPath = $userDir.FullName
    $destination = "${remoteName}:${bucketName}/${username}/"

    Write-Host ""
    Write-Host "Backing up user: $username" -ForegroundColor Cyan
    Write-Host "  Source: $userPath"
    Write-Host "  Destination: $destination"

    # Check if we have access
    try {
        $null = Get-ChildItem $userPath -ErrorAction Stop
    } catch {
        if ($isAdmin) {
            Write-Host "  Warning: Limited access to $username's files" -ForegroundColor Yellow
        } else {
            Write-Host "  Skipping: No access to $username's files (run as Administrator)" -ForegroundColor Yellow
            $failedUsers += $username
            continue
        }
    }

    # Run backup
    $startTime = Get-Date
    $logFile = "$env:TEMP\backup-$username-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

    rclone sync $userPath $destination `
        --exclude-from $excludesFile `
        --transfers 8 `
        --checkers 8 `
        --fast-list `
        --skip-links `
        --ignore-errors `
        --retries 10 `
        --retries-sleep 2s `
        --low-level-retries 20 `
        --no-update-modtime `
        --progress `
        --stats 10s `
        --log-file $logFile `
        --log-level INFO

    $endTime = Get-Date
    $duration = [math]::Round(($endTime - $startTime).TotalMinutes, 2)

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Backup complete for $username in $duration minutes" -ForegroundColor Green
    } else {
        Write-Host "⚠ Backup completed with warnings for $username (check log: $logFile)" -ForegroundColor Yellow
        $failedUsers += $username
    }
}

# Update machine info with backup status
$machineInfo.backup_info = @{
    backup_performed = $true
    backup_destination = "${remoteName}:${bucketName}/"
    backup_timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
}

$machineInfo | ConvertTo-Json -Depth 10 | Out-File -FilePath $machineInfoFile -Encoding UTF8

# Upload machine info to B2
Write-Host ""
Write-Host "Uploading machine info to B2..." -ForegroundColor Yellow
rclone copy $machineInfoFile "${remoteName}:${bucketName}/" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ Machine info uploaded to B2" -ForegroundColor Green
}

# Summary
Write-Host ""
Write-Host "=== Backup Summary ===" -ForegroundColor Cyan
Write-Host "Total users processed: $($userDirs.Count)"
Write-Host "Successful: $($userDirs.Count - $failedUsers.Count)"
if ($failedUsers.Count -gt 0) {
    Write-Host "Failed/Skipped users: $($failedUsers -join ', ')" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Decommission Process Complete ===" -ForegroundColor Cyan
Write-Host "Machine Info: $machineInfoFile"
Write-Host "Remote: $remoteName"
Write-Host "Bucket: $bucketName"
Write-Host "Logs: $env:TEMP\backup-*.log"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Review backup logs for any errors"
Write-Host "2. Verify files in B2 console"
Write-Host "3. Save machine info file to secure location"
Write-Host "4. Proceed with machine wipe"