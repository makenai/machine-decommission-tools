# Windows PowerShell Decommission Script

A simplified Windows-native version of the machine decommission tool.

## Prerequisites

1. **Install rclone**: Download from https://rclone.org/downloads/
   - Download the Windows ZIP file
   - Extract to `C:\rclone\`
   - Add `C:\rclone` to your PATH environment variable

2. **B2 Account**: Get your Application Key ID and Key from Backblaze

## Usage

### Run as Administrator (Recommended)

1. Open PowerShell as Administrator (right-click → Run as Administrator)
2. Navigate to the script directory
3. Run the script:

```powershell
# If execution policy blocks scripts:
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

# Run the decommission script
.\decommission.ps1
```

### Environment Variables (Optional)

Skip credential prompts by setting environment variables first:

```powershell
$env:B2_APPLICATION_KEY_ID = "your-key-id"
$env:B2_APPLICATION_KEY = "your-key"
$env:B2_BUCKET_NAME = "your-bucket"

.\decommission.ps1
```

## What it Does

1. **Collects Windows system information**
   - Hardware details (serial, model, CPU, memory)
   - Windows version and build
   - BitLocker encryption status
   - Network adapters and MAC addresses
   - Disk usage

2. **Backs up all user directories**
   - Automatically finds all user directories in C:\Users
   - Skips system directories (Public, Default, etc.)
   - Excludes cache files, temp files, and other unnecessary data
   - When run as Administrator, can backup all users
   - When run as regular user, only backs up accessible directories

3. **Creates organized backup structure**
   - Creates subfolder named: `COMPUTERNAME-YYYYMMDD-HHMMSS`
   - Each user gets their own subfolder
   - Machine info JSON saved to backup and locally

## Output

- **Local machine info**: `%USERPROFILE%\machine-info-*.json`
- **Backup logs**: `%TEMP%\backup-*.log`
- **B2 structure**: `bucket/COMPUTERNAME-timestamp/username/`

## Differences from Bash Version

This PowerShell version:
- Runs natively on Windows (no WSL required)
- Has proper access to Windows permissions when run as Administrator
- Automatically backs up all users (no selection prompt)
- Simplified configuration (fewer options)
- Uses Windows-specific paths and commands

## Troubleshooting

### "Cannot be loaded because running scripts is disabled"
Run: `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process`

### "rclone is not recognized"
Make sure rclone is in your PATH or specify the full path to rclone.exe

### "Access denied" errors
Run PowerShell as Administrator to backup all users

### "Cannot connect to B2"
Check your B2 credentials and internet connection