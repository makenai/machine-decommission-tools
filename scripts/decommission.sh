#!/bin/bash
# Machine Decommission Tool
# https://github.com/yourusername/machine-decommission-tools

set -eo pipefail

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Global variables
# Handle both direct execution and curl pipe execution
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$PWD"
fi
MULTI_USER_MODE=false
SELECTED_USERS=()
BACKUP_SUBFOLDER=""
IS_ADMIN=false
MACHINE_INFO_FILE=""
EXCLUDES_FILE=""

echo -e "${BLUE}=== Machine Decommission Tool ===${NC}"
echo -e "${YELLOW}This tool will capture machine info and backup user data before decommissioning${NC}\n"

# Function to read input that works with piped scripts
read_input() {
    local prompt="$1"
    local var_name="$2"
    
    if [ -t 0 ]; then
        # Normal read when running interactively
        read -p "$prompt" input_value
    else
        # Read from /dev/tty when piped
        read -p "$prompt" input_value < /dev/tty
    fi
    
    # Assign to the specified variable
    eval "$var_name='$input_value'"
}

# Function to read secure input (passwords)
read_secure() {
    local prompt="$1"
    local var_name="$2"
    
    if [ -t 0 ]; then
        read -s -p "$prompt" input_value
    else
        read -s -p "$prompt" input_value < /dev/tty
    fi
    echo  # New line after password input
    
    # Assign to the specified variable
    eval "$var_name='$input_value'"
}

# Function to check if running as admin/root
check_admin_privileges() {
    if [[ $EUID -eq 0 ]]; then
        IS_ADMIN=true
        echo -e "${GREEN}✓ Running with administrator privileges${NC}"
        return 0
    elif sudo -n true 2>/dev/null; then
        IS_ADMIN=true
        echo -e "${GREEN}✓ Can use sudo without password${NC}"
        return 0
    else
        echo -e "${YELLOW}Running as regular user - will backup current user only${NC}"
        return 1
    fi
}

# Function to collect comprehensive machine information
collect_machine_info() {
    echo -e "\n${YELLOW}Collecting machine information...${NC}"
    
    local timestamp=$(date +%Y%m%d-%H%M%S)
    MACHINE_INFO_FILE="$HOME/machine-info-${timestamp}.json"
    
    # Common info for all platforms
    local hostname=$(hostname)
    local timestamp_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local current_user=$(whoami)
    local home_dir="$HOME"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS specific collection
        local serial=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Serial Number" | awk '{print $4}' || echo "N/A")
        local model=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Model Name" | cut -d: -f2 | xargs || echo "N/A")
        local model_id=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Model Identifier" | cut -d: -f2 | xargs || echo "N/A")
        local cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "N/A")
        local cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "0")
        local memory=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Memory" | cut -d: -f2 | xargs || echo "N/A")
        local uuid=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Hardware UUID" | cut -d: -f2 | xargs || echo "N/A")
        local os_version=$(sw_vers -productVersion 2>/dev/null || echo "N/A")
        local build=$(sw_vers -buildVersion 2>/dev/null || echo "N/A")
        local boot_rom=$(system_profiler SPHardwareDataType 2>/dev/null | grep "System Firmware Version" | cut -d: -f2 | xargs || echo "N/A")
        local os_type="macOS"
        
        # Additional useful info
        local boot_volume=$(diskutil info / 2>/dev/null | grep "Device Identifier" | awk '{print $3}' || echo "N/A")
        local file_vault=$(fdesetup status 2>/dev/null | cut -d' ' -f3 || echo "Unknown")
        local sip_status=$(csrutil status 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
        
        # Get all MAC addresses
        local macs=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && macs+=("\"$line\"")
        done < <(ifconfig 2>/dev/null | grep "ether" | awk '{print $2}' | sort -u)
        local mac_list=$(IFS=,; echo "${macs[*]}")
        
        # Storage info
        local total_disk=$(df -H / 2>/dev/null | awk 'NR==2 {print $2}' || echo "N/A")
        local used_disk=$(df -H / 2>/dev/null | awk 'NR==2 {print $3}' || echo "N/A")
        local free_disk=$(df -H / 2>/dev/null | awk 'NR==2 {print $4}' || echo "N/A")
        
    else
        # Linux specific collection
        local serial=$(sudo dmidecode -s system-serial-number 2>/dev/null || echo "N/A")
        local uuid=$(sudo dmidecode -s system-uuid 2>/dev/null || cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo "N/A")
        local manufacturer=$(sudo dmidecode -s system-manufacturer 2>/dev/null || echo "N/A")
        local model=$(sudo dmidecode -s system-product-name 2>/dev/null || echo "N/A")
        local model_id=$(sudo dmidecode -s system-version 2>/dev/null || echo "N/A")
        local cpu=$(lscpu 2>/dev/null | grep "Model name" | cut -d: -f2 | xargs || echo "N/A")
        local cores=$(nproc 2>/dev/null || echo "0")
        local memory=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo "N/A")
        local os_version=$(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "N/A")
        local build=$(uname -r 2>/dev/null || echo "N/A")
        local boot_rom=$(sudo dmidecode -s bios-version 2>/dev/null || echo "N/A")
        local os_type="Linux"
        
        # Additional info
        local boot_volume=$(findmnt -n -o SOURCE / 2>/dev/null || echo "N/A")
        local file_vault="N/A"  # Check for LUKS
        if command -v cryptsetup &>/dev/null; then
            cryptsetup status /dev/mapper/* 2>/dev/null | grep -q "is active" && file_vault="Encrypted"
        fi
        local sip_status="N/A"
        
        # MAC addresses
        local macs=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && macs+=("\"$line\"")
        done < <(ip link show 2>/dev/null | grep "link/ether" | awk '{print $2}' | sort -u)
        local mac_list=$(IFS=,; echo "${macs[*]}")
        
        # Storage info
        local total_disk=$(df -H / 2>/dev/null | awk 'NR==2 {print $2}' || echo "N/A")
        local used_disk=$(df -H / 2>/dev/null | awk 'NR==2 {print $3}' || echo "N/A")
        local free_disk=$(df -H / 2>/dev/null | awk 'NR==2 {print $4}' || echo "N/A")
    fi
    
    # Get list of all users on system
    local all_users=()
    while IFS='|' read -r username home; do
        [[ -n "$username" ]] && all_users+=("\"$username\"")
    done < <(list_system_users)
    local users_list=$(IFS=,; echo "${all_users[*]}")
    
    # Create comprehensive JSON
    cat > "$MACHINE_INFO_FILE" << EOF
{
  "metadata": {
    "timestamp": "$timestamp_iso",
    "decommission_tool_version": "1.0",
    "decommissioned_by": "$current_user",
    "decommission_reason": "manual"
  },
  "system": {
    "hostname": "$hostname",
    "os_type": "$os_type",
    "os_version": "$os_version",
    "kernel_build": "$build",
    "boot_volume": "$boot_volume",
    "encryption_status": "$file_vault",
    "sip_status": "$sip_status"
  },
  "hardware": {
    "serial_number": "$serial",
    "hardware_uuid": "$uuid",
    "manufacturer": "${manufacturer:-N/A}",
    "model": "$model",
    "model_identifier": "$model_id",
    "cpu": "$cpu",
    "cpu_cores": $cores,
    "memory": "$memory",
    "firmware_version": "$boot_rom"
  },
  "storage": {
    "total_capacity": "$total_disk",
    "used_space": "$used_disk",
    "free_space": "$free_disk",
    "boot_device": "$boot_volume"
  },
  "network": {
    "mac_addresses": [$mac_list]
  },
  "users": {
    "current_user": "$current_user",
    "all_system_users": [$users_list],
    "total_users": ${#all_users[@]}
  },
  "backup_info": {
    "backup_performed": false,
    "backup_destination": "",
    "backup_timestamp": ""
  }
}
EOF
    
    chmod 600 "$MACHINE_INFO_FILE"
    echo -e "${GREEN}✓ Machine information saved to: $MACHINE_INFO_FILE${NC}"
    
    # Display summary
    echo -e "\n${BLUE}Machine Summary:${NC}"
    echo "  Model: $model"
    echo "  Serial: $serial"
    echo "  OS: $os_type $os_version"
    echo "  Storage: $used_disk used of $total_disk"
    echo "  Users: ${#all_users[@]} total"
}

# Function to list system users
list_system_users() {
    local users=()
    local min_uid=1000  # Typically regular users start at UID 1000
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        min_uid=501
        while IFS=: read -r username _ uid _ _ home_dir _; do
            if [[ $uid -ge $min_uid && -d "$home_dir" && "$home_dir" != "/var/empty" ]]; then
                users+=("$username|$home_dir")
            fi
        done < <(dscl . -list /Users NFSHomeDirectory | while read username homedir; do
            if [[ "$homedir" != "/var/empty" && -d "$homedir" ]]; then
                local uid=$(dscl . -read /Users/"$username" UniqueID 2>/dev/null | awk '{print $2}')
                if [[ -n "$uid" && $uid -ge $min_uid ]]; then
                    echo "$username:x:$uid:x:x:$homedir:x"
                fi
            fi
        done)
    else
        # Linux
        while IFS=: read -r username _ uid _ _ home_dir _; do
            if [[ $uid -ge $min_uid && -d "$home_dir" && "$username" != "nobody" ]]; then
                users+=("$username|$home_dir")
            fi
        done < /etc/passwd
    fi
    
    printf '%s\n' "${users[@]}"
}

# Function to prompt for user selection
select_users_to_backup() {
    local available_users=()
    
    echo -e "\n${YELLOW}Detecting system users...${NC}"
    
    while IFS='|' read -r username home_dir; do
        if [[ -n "$username" ]]; then
            available_users+=("$username|$home_dir")
        fi
    done < <(list_system_users)
    
    if [[ ${#available_users[@]} -eq 0 ]]; then
        echo -e "${RED}No regular users found${NC}"
        return 1
    fi
    
    echo -e "\n${BLUE}Available users:${NC}"
    local i=1
    for user_info in "${available_users[@]}"; do
        IFS='|' read -r username home_dir <<< "$user_info"
        printf "  %2d) %-20s %s\n" "$i" "$username" "$home_dir"
        ((i++))
    done
    
    echo -e "\n${YELLOW}Select users to backup:${NC}"
    echo "  a) All users"
    echo "  c) Current user only ($(whoami))"
    echo "  s) Select specific users (comma-separated numbers)"
    
    read_input "Your choice [c]: " choice
    choice=${choice:-c}
    
    case "$choice" in
        a|A)
            SELECTED_USERS=("${available_users[@]}")
            MULTI_USER_MODE=true
            ;;
        s|S)
            read_input "Enter user numbers (e.g., 1,3,4): " selections
            IFS=',' read -ra selected_indices <<< "$selections"
            for index in "${selected_indices[@]}"; do
                index=$((index - 1))
                if [[ $index -ge 0 && $index -lt ${#available_users[@]} ]]; then
                    SELECTED_USERS+=("${available_users[$index]}")
                fi
            done
            if [[ ${#SELECTED_USERS[@]} -gt 1 ]]; then
                MULTI_USER_MODE=true
            fi
            ;;
        *)
            # Current user only
            local current_user="$(whoami)"
            local current_home="$HOME"
            SELECTED_USERS=("$current_user|$current_home")
            ;;
    esac
    
    echo -e "\n${GREEN}Selected users for backup:${NC}"
    for user_info in "${SELECTED_USERS[@]}"; do
        IFS='|' read -r username home_dir <<< "$user_info"
        echo "  - $username ($home_dir)"
    done
}

# Function to prompt for backup subfolder
setup_backup_subfolder() {
    echo -e "\n${YELLOW}Backup organization options:${NC}"
    echo "  1) Backup directly to bucket root"
    echo "  2) Create a subfolder for this backup session"
    echo "  3) Use machine hostname as subfolder ($(hostname -s))"
    echo "  4) Use date as subfolder ($(date +%Y-%m-%d))"
    echo "  5) Custom subfolder name"
    
    read_input "Your choice [1]: " folder_choice
    folder_choice=${folder_choice:-1}
    
    case "$folder_choice" in
        2)
            BACKUP_SUBFOLDER="backup-$(date +%Y%m%d-%H%M%S)"
            ;;
        3)
            BACKUP_SUBFOLDER="$(hostname -s)"
            ;;
        4)
            BACKUP_SUBFOLDER="$(date +%Y-%m-%d)"
            ;;
        5)
            read_input "Enter subfolder name: " custom_folder
            BACKUP_SUBFOLDER="$custom_folder"
            ;;
        *)
            BACKUP_SUBFOLDER=""
            ;;
    esac
    
    if [[ -n "$BACKUP_SUBFOLDER" ]]; then
        echo -e "${GREEN}✓ Will backup to subfolder: $BACKUP_SUBFOLDER${NC}"
    fi
}

# Function to create excludes file
create_excludes_file() {
    local excludes_file="$HOME/.backup-excludes"
    
    if [[ ! -f "$excludes_file" ]]; then
        echo -e "${YELLOW}Creating backup excludes file...${NC}"
        cat > "$excludes_file" << 'EOF'
# Caches and temporary files
.cache/**
Cache/**
Caches/**
.npm/**
.docker/**
.Trash/**
node_modules/**
.wine/**
.minikube/**
.kube/**
.gradle/**
.m2/**
.expo/**
.nvm/**
.turtle/**
.node-gyp/**
.cargo/**
.local/share/Trash/**
.local/share/baloo/**
.vscode/**
.vscode-insiders/**
venv/**
.venv/**
**/venv/**
**/.venv/**

# Library stuff (macOS)
Library/Caches/**
Library/Developer/**
Library/Containers/**
Library/Application Support/Steam/**
Library/Application Support/Spotify/**
Library/CloudStorage/**
Library/Application Support/Google/Chrome/**
Library/Application Support/Firefox/**
Library/Logs/**
Library/WebKit/**
Library/Safari/**

# Library stuff (Linux)
.mozilla/firefox/*/Cache/**
.config/google-chrome/*/Cache/**
.config/chromium/*/Cache/**
.steam/**
.local/share/Steam/**

# Build artifacts
**/dist/**
**/build/**
**/target/**
**/.next/**
**/out/**
**/__pycache__/**
**/*.pyc
**/.pytest_cache/**
.elixir_ls/**
**/_build/**
**/deps/**

# System files
.DS_Store
Thumbs.db
desktop.ini
*.tmp
*.temp
*.log
**/*.log
.Spotlight-V100
.Trashes
.fseventsd
.DocumentRevisions-V100
.TemporaryItems

# Large files
*.sql
*.sql.gz
*.iso
*.dmg
*.img
*.vmdk
*.vdi
*.box
*.ova
masked_sql/**

# History files
.zsh_history
.bash_history
.python_history
.node_repl_history
.viminfo
.lesshst
.mysql_history
.psql_history
.sqlite_history

# Version control
**/.git/objects/**
**/.git/lfs/**
**/.svn/**
**/.hg/**

# Package managers
.rbenv/**
.pyenv/**
.jenv/**
.sdkman/**
.rustup/**
.composer/cache/**

# IDE specific
.idea/**
*.iml
.eclipse/**
.netbeans/**

# Virtual machines
VirtualBox VMs/**
.vagrant/**
.vagrant.d/**

# Backup files
*.bak
*.backup
*~
*.swp
*.swo

# Script-created files (don't backup our own files)
.last-backup-config
.backup-excludes
machine-info-*.json

# Other
.zcompdump*
.android/**
.gradle/**
.wine/**
.Xauthority
.ICEauthority
EOF
        echo -e "${GREEN}✓ Created excludes file${NC}"
    else
        echo -e "${GREEN}✓ Using existing excludes file${NC}"
    fi
    
    echo "$excludes_file"
}

# Function to check/get B2 credentials
setup_b2_credentials() {
    if [[ -z "${B2_APPLICATION_KEY_ID:-}" ]]; then
        echo -e "${YELLOW}B2 Application Key ID not found in environment${NC}"
        read_input "Enter your B2 Application Key ID: " B2_APPLICATION_KEY_ID
        export B2_APPLICATION_KEY_ID
    else
        echo -e "${GREEN}✓ Using B2 Application Key ID from environment${NC}"
    fi

    if [[ -z "${B2_APPLICATION_KEY:-}" ]]; then
        echo -e "${YELLOW}B2 Application Key not found in environment${NC}"
        read_secure "Enter your B2 Application Key: " B2_APPLICATION_KEY
        export B2_APPLICATION_KEY
    else
        echo -e "${GREEN}✓ Using B2 Application Key from environment${NC}"
    fi
    
    # Validate credentials format
    if [[ ! "$B2_APPLICATION_KEY_ID" =~ ^[0-9a-zA-Z]+$ ]]; then
        echo -e "${RED}Error: Invalid B2 Application Key ID format${NC}"
        exit 1
    fi
    
    if [[ ${#B2_APPLICATION_KEY} -lt 20 ]]; then
        echo -e "${RED}Error: B2 Application Key seems too short${NC}"
        exit 1
    fi
}

# Function to get bucket configuration
setup_bucket_config() {
    if [[ -z "${B2_BUCKET_NAME:-}" ]]; then
        while [[ -z "$B2_BUCKET_NAME" ]]; do
            read_input "Enter your B2 bucket name: " B2_BUCKET_NAME
            if [[ -z "$B2_BUCKET_NAME" ]]; then
                echo -e "${RED}Bucket name cannot be empty${NC}"
            fi
        done
        export B2_BUCKET_NAME
    else
        echo -e "${GREEN}✓ Using bucket: $B2_BUCKET_NAME${NC}"
    fi

    if [[ -z "${B2_REMOTE_NAME:-}" ]]; then
        read_input "Enter a name for this backup remote [default: backup-remote]: " B2_REMOTE_NAME
        B2_REMOTE_NAME=${B2_REMOTE_NAME:-backup-remote}
        export B2_REMOTE_NAME
    else
        echo -e "${GREEN}✓ Using remote name: $B2_REMOTE_NAME${NC}"
    fi
}

# Function to check dependencies
check_dependencies() {
    local missing_deps=()
    
    if ! command -v rclone &> /dev/null; then
        missing_deps+=("rclone")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        echo -e "${RED}Error: Missing required dependencies: ${missing_deps[*]}${NC}"
        echo -e "\nInstallation instructions:"
        echo -e "macOS:    brew install ${missing_deps[*]}"
        echo -e "Ubuntu:   sudo apt install ${missing_deps[*]}"
        echo -e "Other:    Visit https://rclone.org/downloads/"
        exit 1
    fi
    
    echo -e "${GREEN}✓ All dependencies installed${NC}"
}

# Function to configure rclone
configure_rclone() {
    # Create new remote if needed and not using existing
    if [[ "$SKIP_CREDENTIALS" != "true" ]]; then
        if rclone listremotes 2>/dev/null | grep -q "^${B2_REMOTE_NAME}:$"; then
            echo -e "${GREEN}✓ Remote '$B2_REMOTE_NAME' already configured${NC}"
        else
            echo -e "${YELLOW}Configuring rclone remote...${NC}"
            # Create rclone config programmatically
            rclone config create "$B2_REMOTE_NAME" b2 \
                account "$B2_APPLICATION_KEY_ID" \
                key "$B2_APPLICATION_KEY" \
                hard_delete true
            echo -e "${GREEN}✓ Created remote '$B2_REMOTE_NAME'${NC}"
        fi
    fi
    
    # Test the connection
    echo -e "${YELLOW}Testing B2 connection...${NC}"
    if rclone lsd "${B2_REMOTE_NAME}:" &> /dev/null; then
        echo -e "${GREEN}✓ Successfully connected to B2${NC}"
    else
        echo -e "${RED}Error: Could not connect to B2. Check your credentials.${NC}"
        exit 1
    fi
    
    # Check if bucket exists
    if ! rclone lsd "${B2_REMOTE_NAME}:" | grep -q " ${B2_BUCKET_NAME}$"; then
        echo -e "${YELLOW}Bucket '$B2_BUCKET_NAME' not found. Creating...${NC}"
        if rclone mkdir "${B2_REMOTE_NAME}:${B2_BUCKET_NAME}"; then
            echo -e "${GREEN}✓ Created bucket '$B2_BUCKET_NAME'${NC}"
        else
            echo -e "${RED}Error: Could not create bucket${NC}"
            exit 1
        fi
    fi
}

# Function to estimate backup size for a user
estimate_user_size() {
    local username="$1"
    local home_dir="$2"
    
    echo -e "\n${YELLOW}Estimating backup size for $username...${NC}"
    
    if [[ -r "$home_dir" ]]; then
        local total_size=$(du -sh "$home_dir" 2>/dev/null | cut -f1)
        echo -e "Total home directory size: ${total_size:-Unknown}"
        
        # Rough estimate using find with excludes
        local file_count=$(find "$home_dir" -type f 2>/dev/null | wc -l)
        echo -e "Total files: ${file_count}"
    else
        echo -e "${YELLOW}Cannot estimate size - insufficient permissions${NC}"
    fi
}

# Function to determine optimal transfer settings
optimize_transfer_settings() {
    local cpu_count=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    local mem_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo 8)
    
    # Conservative defaults
    local transfers=8
    local checkers=8
    
    # Adjust based on system resources
    if [[ $cpu_count -ge 8 ]]; then
        transfers=16
        checkers=16
    elif [[ $cpu_count -ge 4 ]]; then
        transfers=12
        checkers=12
    fi
    
    # Check if we're on a fast connection (optional bandwidth test)
    if command -v speedtest-cli &> /dev/null; then
        echo -e "${YELLOW}Testing connection speed (this may take a moment)...${NC}"
        local upload_mbps=$(speedtest-cli --no-download --csv 2>/dev/null | cut -d',' -f8 | cut -d'.' -f1)
        if [[ -n "$upload_mbps" && "$upload_mbps" -gt 100 ]]; then
            transfers=$((transfers * 2))
            echo -e "${GREEN}✓ Fast connection detected (${upload_mbps} Mbps)${NC}"
        fi
    fi
    
    echo "$transfers $checkers"
}

# Function to run backup for a single user
backup_user() {
    local username="$1"
    local home_dir="$2"
    local destination_path="${B2_REMOTE_NAME}:${B2_BUCKET_NAME}/"
    
    # Add subfolder if specified
    if [[ -n "$BACKUP_SUBFOLDER" ]]; then
        destination_path="${destination_path}${BACKUP_SUBFOLDER}/"
    fi
    
    # Add username folder if in multi-user mode
    if [[ "$MULTI_USER_MODE" == true ]]; then
        destination_path="${destination_path}${username}/"
    fi
    
    echo -e "\n${BLUE}Backing up user: $username${NC}"
    echo -e "Source: $home_dir"
    echo -e "Destination: $destination_path"
    
    # Check if we have read access
    if [[ ! -r "$home_dir" ]]; then
        if [[ "$IS_ADMIN" == true ]]; then
            echo -e "${YELLOW}Using sudo to access $username's files${NC}"
            local sudo_prefix="sudo"
        else
            echo -e "${RED}Error: Cannot read $home_dir - insufficient permissions${NC}"
            return 1
        fi
    else
        local sudo_prefix=""
    fi
    
    # Get optimized settings
    read -r transfers checkers <<< $(optimize_transfer_settings)
    
    # Save start time
    local start_time=$(date +%s)
    local log_file="/tmp/backup-${username}-$(date +%Y%m%d-%H%M%S).log"
    
    # Run the backup
    $sudo_prefix rclone sync "$home_dir" "$destination_path" \
        --exclude-from "$EXCLUDES_FILE" \
        --transfers "$transfers" \
        --checkers "$checkers" \
        --fast-list \
        --skip-links \
        --ignore-errors \
        --retries 10 \
        --retries-sleep 2s \
        --low-level-retries 20 \
        --no-update-modtime \
        --progress \
        --stats 10s \
        --log-file "$log_file" \
        --log-level INFO \
        --exclude ".Trash/**" \
        --exclude ".Trashes/**" \
        --exclude "Library/Caches/**" \
        --exclude ".cache/**"
    
    local exit_code=$?
    
    # Calculate elapsed time
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local elapsed_mins=$((elapsed / 60))
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}✓ Backup complete for $username in ${elapsed_mins} minutes${NC}"
    else
        echo -e "${YELLOW}⚠ Backup completed with warnings for $username (check log: $log_file)${NC}"
    fi
    
    
    return $exit_code
}

# Function to run all backups
run_backups() {
    local dry_run_first=true
    
    if [[ ${#SELECTED_USERS[@]} -gt 1 ]]; then
        echo -e "\n${YELLOW}You have selected ${#SELECTED_USERS[@]} users for backup${NC}"
        read_input "Skip dry run for faster backup? [y/N]: " skip_dry
        if [[ "$skip_dry" =~ ^[Yy]$ ]]; then
            dry_run_first=false
        fi
    else
        read_input "Do you want to see a dry run first? [Y/n]: " dry_run
        dry_run=${dry_run:-Y}
        if [[ ! "$dry_run" =~ ^[Yy]$ ]]; then
            dry_run_first=false
        fi
    fi
    
    if [[ "$dry_run_first" == true ]]; then
        echo -e "\n${YELLOW}Running dry run...${NC}"
        for user_info in "${SELECTED_USERS[@]:0:1}"; do  # Only dry run first user
            IFS='|' read -r username home_dir <<< "$user_info"
            
            local dest_path="${B2_REMOTE_NAME}:${B2_BUCKET_NAME}/"
            [[ -n "$BACKUP_SUBFOLDER" ]] && dest_path="${dest_path}${BACKUP_SUBFOLDER}/"
            [[ "$MULTI_USER_MODE" == true ]] && dest_path="${dest_path}${username}/"
            
            rclone sync "$home_dir" "$dest_path" \
                --exclude-from "$EXCLUDES_FILE" \
                --skip-links \
                --dry-run \
                --progress \
                --max-depth 3  # Limit dry run depth for speed
        done
        
        echo -e "\n${YELLOW}Dry run complete. Review the output above.${NC}"
        read_input "Proceed with actual backup? [y/N]: " proceed
        
        if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Backup cancelled${NC}"
            exit 0
        fi
    fi
    
    echo -e "\n${BLUE}Starting backups...${NC}"
    echo -e "${YELLOW}This may take a while depending on data size and connection speed${NC}\n"
    
    local failed_users=()
    
    for user_info in "${SELECTED_USERS[@]}"; do
        IFS='|' read -r username home_dir <<< "$user_info"
        
        if ! backup_user "$username" "$home_dir"; then
            failed_users+=("$username")
        fi
    done
    
    # Summary
    echo -e "\n${BLUE}=== Backup Summary ===${NC}"
    echo -e "Total users processed: ${#SELECTED_USERS[@]}"
    echo -e "Successful: $((${#SELECTED_USERS[@]} - ${#failed_users[@]}))"
    
    if [[ ${#failed_users[@]} -gt 0 ]]; then
        echo -e "${RED}Failed users: ${failed_users[*]}${NC}"
    fi
}

# Function to save backup config
save_backup_config() {
    local config_file="$HOME/.last-backup-config"
    
    echo -e "\n${YELLOW}Saving backup configuration...${NC}"
    cat > "$config_file" << EOF
B2_REMOTE_NAME=${B2_REMOTE_NAME}
B2_BUCKET_NAME=${B2_BUCKET_NAME}
BACKUP_SUBFOLDER=${BACKUP_SUBFOLDER}
BACKUP_DATE=$(date)
MULTI_USER_MODE=${MULTI_USER_MODE}
SELECTED_USERS=(${SELECTED_USERS[@]})
MACHINE_INFO_FILE=${MACHINE_INFO_FILE}
EOF
    
    chmod 600 "$config_file"
    echo -e "${GREEN}✓ Configuration saved to $config_file${NC}"
}

# Function to update machine info with backup status
update_machine_info_backup_status() {
    if [[ -f "$MACHINE_INFO_FILE" ]]; then
        echo -e "\n${YELLOW}Updating machine info with backup details...${NC}"
        
        local backup_dest="${B2_REMOTE_NAME}:${B2_BUCKET_NAME}/"
        [[ -n "$BACKUP_SUBFOLDER" ]] && backup_dest="${backup_dest}${BACKUP_SUBFOLDER}/"
        
        # Create a temporary file with updated backup info
        local temp_file="${MACHINE_INFO_FILE}.tmp"
        
        # Use jq if available, otherwise use sed
        if command -v jq &> /dev/null; then
            jq --arg dest "$backup_dest" \
               --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
               '.backup_info.backup_performed = true | 
                .backup_info.backup_destination = $dest | 
                .backup_info.backup_timestamp = $timestamp' \
               "$MACHINE_INFO_FILE" > "$temp_file"
        else
            # Fallback to sed for updating JSON
            sed -i.bak \
                -e 's/"backup_performed": false/"backup_performed": true/' \
                -e "s|\"backup_destination\": \"\"|\"backup_destination\": \"$backup_dest\"|" \
                -e "s|\"backup_timestamp\": \"\"|\"backup_timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"|" \
                "$MACHINE_INFO_FILE"
        fi
        
        if [[ -f "$temp_file" ]]; then
            mv "$temp_file" "$MACHINE_INFO_FILE"
        fi
        
        chmod 600 "$MACHINE_INFO_FILE"
        echo -e "${GREEN}✓ Machine info updated with backup details${NC}"
    fi
}

# Function to upload machine info to B2
upload_machine_info() {
    if [[ -f "$MACHINE_INFO_FILE" && -n "${B2_REMOTE_NAME:-}" && -n "${B2_BUCKET_NAME:-}" ]]; then
        echo -e "\n${YELLOW}Uploading machine info to B2...${NC}"
        
        local dest_path="${B2_REMOTE_NAME}:${B2_BUCKET_NAME}/"
        [[ -n "$BACKUP_SUBFOLDER" ]] && dest_path="${dest_path}${BACKUP_SUBFOLDER}/"
        
        if rclone copy "$MACHINE_INFO_FILE" "$dest_path" 2>/dev/null; then
            echo -e "${GREEN}✓ Machine info uploaded to B2${NC}"
            
            # Also copy to user's backup folder if backing up single user
            if [[ "$MULTI_USER_MODE" == false ]]; then
                local username=$(whoami)
                rclone copy "$MACHINE_INFO_FILE" "${dest_path}${username}/" 2>/dev/null
            fi
        else
            echo -e "${YELLOW}⚠ Could not upload machine info to B2${NC}"
        fi
    fi
}

# Main execution
main() {
    echo -e "${YELLOW}Checking system...${NC}"
    check_dependencies
    
    # Collect machine information first
    collect_machine_info
    
    # Create excludes file once for all backups
    EXCLUDES_FILE=$(create_excludes_file)
    
    # Check admin privileges and offer multi-user backup
    if check_admin_privileges; then
        echo -e "\n${YELLOW}Multi-user backup available${NC}"
        read_input "Backup multiple users? [y/N]: " multi_user
        if [[ "$multi_user" =~ ^[Yy]$ ]]; then
            select_users_to_backup
        else
            SELECTED_USERS=("$(whoami)|$HOME")
        fi
    else
        SELECTED_USERS=("$(whoami)|$HOME")
    fi
    
    setup_backup_subfolder
    
    echo -e "\n${YELLOW}Setting up B2 configuration...${NC}"
    
    # Initialize flags
    SKIP_CREDENTIALS=false
    
    # Check for existing remotes first
    local existing_remotes=()
    while IFS= read -r remote; do
        remote="${remote%:}"
        if [[ -n "$remote" ]]; then
            existing_remotes+=("$remote")
        fi
    done < <(rclone listremotes 2>/dev/null)
    
    if [[ ${#existing_remotes[@]} -gt 0 ]]; then
        echo -e "\n${YELLOW}Found existing rclone remotes:${NC}"
        echo "  n) Create new remote"
        local i=1
        for remote in "${existing_remotes[@]}"; do
            local remote_type=$(rclone config show "$remote" 2>/dev/null | grep "^type = " | cut -d' ' -f3)
            printf "  %d) %s" "$i" "$remote"
            [[ "$remote_type" == "b2" ]] && printf " (B2)"
            printf "\n"
            ((i++))
        done
        
        read_input "Select remote or create new [n]: " remote_choice
        remote_choice=${remote_choice:-n}
        
        if [[ "$remote_choice" != "n" && "$remote_choice" != "N" ]]; then
            local selected_index=$((remote_choice - 1))
            if [[ $selected_index -ge 0 && $selected_index -lt ${#existing_remotes[@]} ]]; then
                B2_REMOTE_NAME="${existing_remotes[$selected_index]}"
                echo -e "${GREEN}✓ Using existing remote '$B2_REMOTE_NAME'${NC}"
                SKIP_CREDENTIALS=true
                export B2_REMOTE_NAME
            fi
        fi
    fi
    
    # Setup credentials and bucket config if creating new remote
    if [[ "$SKIP_CREDENTIALS" != "true" ]]; then
        setup_b2_credentials
        setup_bucket_config
    else
        # Still need bucket name even with existing remote
        setup_bucket_config
    fi
    
    configure_rclone
    
    # Estimate sizes
    for user_info in "${SELECTED_USERS[@]}"; do
        IFS='|' read -r username home_dir <<< "$user_info"
        estimate_user_size "$username" "$home_dir" "$EXCLUDES_FILE"
    done
    
    run_backups
    save_backup_config
    
    # Update machine info with backup details
    update_machine_info_backup_status
    
    # Upload machine info to B2
    upload_machine_info
    
    echo -e "\n${BLUE}=== Decommission Process Complete ===${NC}"
    echo -e "Machine Info: $MACHINE_INFO_FILE"
    echo -e "Remote: ${B2_REMOTE_NAME}"
    echo -e "Bucket: ${B2_BUCKET_NAME}"
    [[ -n "$BACKUP_SUBFOLDER" ]] && echo -e "Subfolder: ${BACKUP_SUBFOLDER}"
    echo -e "Logs: /tmp/backup-*.log"
    echo -e "\n${YELLOW}Next steps:${NC}"
    echo -e "1. Review backup logs for any errors"
    echo -e "2. Verify files in B2 console"
    echo -e "3. Save machine info file to secure location"
    echo -e "4. Proceed with machine wipe"
}

# Trap to handle interruptions gracefully
trap 'echo -e "\n${RED}Backup interrupted. You can resume by running the script again.${NC}"; exit 1' INT TERM

# Run main function
main "$@"