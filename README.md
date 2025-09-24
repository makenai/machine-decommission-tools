# Machine Decommission Tools

Comprehensive tool for safely decommissioning machines by capturing hardware information and backing up user data.

## Quick Start

```bash
# Run decommission process (captures machine info + backs up data)
curl -sSL https://raw.githubusercontent.com/makenai/machine-decommission-tools/main/scripts/decommission.sh | bash

# For multi-user backup (admin/root required)
sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/makenai/machine-decommission-tools/main/scripts/decommission.sh)"
```

## Features

### Integrated Decommission Process
1. **Machine Information Capture**
   - Hardware details (serial, UUID, model, CPU, memory)
   - Network information (MAC addresses)
   - Storage details and usage
   - User accounts listing
   - System configuration (OS version, encryption status)
   - Saves as `machine-info-TIMESTAMP.json` in home directory

2. **User Data Backup**
   - Automatic exclusion of cache/temp files
   - Multi-user backup support (when run as admin)
   - Flexible subfolder organization
   - Progress tracking and resume capability
   - Optimized transfer settings based on system resources

3. **Automatic Upload**
   - Machine info automatically uploaded to B2
   - Backup status tracked in machine info JSON
   - All data organized in your chosen structure

## Setup

### Prerequisites
- **macOS**: Install Homebrew, then `brew install rclone`
- **Linux**: `sudo apt install rclone` or download from rclone.org
- **B2 Account**: Get your Application Key ID and Key from Backblaze

### First Run
The backup script will prompt for:
1. B2 Application Key ID
2. B2 Application Key
3. Bucket name
4. Backup organization (subfolder options)
5. User selection (if running as admin)

## Advanced Usage

### Multi-User Decommission
Run as administrator to backup multiple users:
```bash
sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/makenai/machine-decommission-tools/main/scripts/decommission.sh)"
```

### Environment Variables
Skip prompts by setting:
```bash
export B2_APPLICATION_KEY_ID="your-key-id"
export B2_APPLICATION_KEY="your-key"
export B2_BUCKET_NAME="your-bucket"
curl -sSL https://raw.githubusercontent.com/makenai/machine-decommission-tools/main/scripts/decommission.sh | bash
```

### Exclude Patterns
Customize exclusions by editing `~/.backup-excludes`

## Recovery

To restore files:
```bash
rclone copy remote:bucket/path ~/restore-location
```

## License
MIT