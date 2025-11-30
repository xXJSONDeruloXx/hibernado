#!/bin/bash
# hibernado Helper Script
# This script sets up hibernation
# Based on: https://github.com/nazar256/publications/blob/main/guides/steam-deck-hibernation.md

set -e

log() {
    echo "[hibernado] $1" >&2
}

ACTION="${1:-status}"

case "$ACTION" in
    status)
        SWAP="/home/swapfile"
        
        if [ ! -f "$SWAP" ]; then
            echo "SWAPFILE_MISSING"
            exit 0
        fi
        
        SWAP_SIZE=$(stat -c "%s" "$SWAP" 2>/dev/null || echo 0)
        TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        MIN_SIZE=$((TOTAL_RAM_KB * 1024))
        if [ "$SWAP_SIZE" -lt "$MIN_SIZE" ]; then
            echo "SWAPFILE_TOO_SMALL"
            exit 0
        fi
        
        if ! swapon --show=NAME | grep -q "$SWAP"; then
            echo "SWAP_INACTIVE"
            exit 0
        fi
        
        if ([ -f /etc/default/grub.d/hibernado.cfg ] && grep -q "resume=" /etc/default/grub.d/hibernado.cfg 2>/dev/null) || \
           ([ -f /etc/default/grub ] && grep -q "resume=" /etc/default/grub 2>/dev/null); then
            :
        else
            echo "RESUME_NOT_CONFIGURED"
            exit 0
        fi
        
        if ! systemctl cat systemd-logind.service 2>/dev/null | grep -q "SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK"; then
            echo "SYSTEMD_NOT_CONFIGURED"
            exit 0
        fi
        
        if [ ! -f /etc/systemd/system/fix-bluetooth-resume.service ]; then
            echo "BLUETOOTH_FIX_MISSING"
            exit 0
        fi
        
        if [ ! -f /etc/systemd/sleep.conf ] || ! grep -q "HibernateDelaySec" /etc/systemd/sleep.conf 2>/dev/null; then
            echo "SLEEP_CONF_NOT_CONFIGURED"
            exit 0
        fi
        
        echo "READY"
        ;;
        
    prepare)
        log "Starting hibernation preparation..."
        
        UUID=$(findmnt -no UUID -T /home)
        if [ -z "$UUID" ]; then
            log "ERROR: Could not find UUID for /home"
            echo "ERROR: Could not determine filesystem UUID for /home" >&2
            exit 1
        fi
        log "Found filesystem UUID: $UUID"
        
        SWAP=/home/swapfile
        log "Setting up hibernation (filesystem-friendly method)..."
        
        NEEDS_RECREATION=false
        if [ -f "$SWAP" ]; then
            SWAP_SIZE=$(stat -c "%s" "$SWAP" 2>/dev/null || echo 0)
            TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            MIN_SIZE=$((TOTAL_RAM_KB * 1024))
            
            if [ "$SWAP_SIZE" -lt "$MIN_SIZE" ]; then
                log "Existing swapfile is too small (${SWAP_SIZE} bytes < ${MIN_SIZE} bytes required)"
                NEEDS_RECREATION=true
            fi
            
            if ! file "$SWAP" | grep -q "swap file"; then
                log "Existing swapfile is invalid"
                NEEDS_RECREATION=true
            fi
        else
            log "Swapfile does not exist"
            NEEDS_RECREATION=true
        fi
        
        if [ "$NEEDS_RECREATION" = true ]; then
            if swapon --show=NAME | grep -q "$SWAP"; then
                log "Deactivating existing swapfile for recreation..."
                swapoff "$SWAP" 2>&1 || log "WARNING: Failed to deactivate swapfile"
            fi
            
            log "Removing old swapfile..."
            rm -f "$SWAP"
            
            SWAP_SIZE_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 + 1024 ))
            log "Creating ${SWAP_SIZE_MB}MB swapfile (RAM + 1GB) using fallocate..."
            
            if ! fallocate -l ${SWAP_SIZE_MB}M "$SWAP" 2>&1; then
                log "ERROR: Failed to create swapfile with fallocate"
                echo "ERROR: Failed to create swapfile" >&2
                exit 1
            fi
            log "Swapfile created successfully"
            
            log "Setting swapfile permissions..."
            chmod 600 "$SWAP"
            
            log "Formatting swapfile..."
            if ! mkswap "$SWAP" >/dev/null 2>&1; then
                log "ERROR: Failed to format swapfile"
                echo "ERROR: Failed to format swapfile" >&2
                exit 1
            fi
            log "Swapfile formatted successfully"
        fi
        
        if ! swapon --show=NAME | grep -q "$SWAP"; then
            log "Activating swapfile with priority for hibernation..."
            if ! swapon -p -1 "$SWAP" 2>&1; then
                log "ERROR: Failed to activate swapfile"
                echo "ERROR: Failed to activate swapfile" >&2
                exit 1
            fi
            
            if swapon --show=NAME,PRIO | grep -q "$SWAP"; then
                SWAP_PRIO=$(swapon --show=NAME,PRIO --noheadings | grep "$SWAP" | awk '{print $2}')
                log "Swapfile activated with priority: $SWAP_PRIO"
            else
                log "ERROR: Swapfile activation verification failed"
                echo "ERROR: Swapfile not showing in active swaps" >&2
                exit 1
            fi
        else
            log "Swapfile already active"
        fi
        
        log "Checking swapfile fragmentation..."
        e4defrag "$SWAP" 2>/dev/null || log "Defrag not needed or not supported"
        
        log "Getting swapfile offset..."
        OFF=$(filefrag -v "$SWAP" | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')
        if [ -z "$OFF" ]; then
            log "ERROR: Could not determine swapfile offset"
            echo "ERROR: Could not determine swapfile offset" >&2
            exit 1
        fi
        
        log "Swapfile UUID: $UUID"
        log "Swapfile offset: $OFF"
        
        log "Creating systemd swap unit..."
        cat > /etc/systemd/system/home-swapfile.swap << EOF
[Unit]
Description=Hibernado Swap File
Documentation=man:systemd.swap(5)

[Swap]
What=$SWAP
Priority=-1

[Install]
WantedBy=swap.target
EOF
        systemctl daemon-reload
        systemctl enable home-swapfile.swap 2>/dev/null || true
        
        if [ ! -f /etc/default/grub.d/hibernado.cfg ]; then
            log "Configuring GRUB for hibernation resume..."
            mkdir -p /etc/default/grub.d
            cat > /etc/default/grub.d/hibernado.cfg << EOF
# hibernado plugin - hibernation resume parameters
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT resume=/dev/disk/by-uuid/$UUID resume_offset=$OFF"
EOF
            if ! update-grub 2>&1; then
                log "WARNING: update-grub failed, may need manual run"
                echo "NOTE: Please run 'sudo update-grub' manually" >&2
            fi
        else
            log "GRUB config already exists"
        fi
        
        log "Configuring systemd-logind..."
        mkdir -p /etc/systemd/system/systemd-logind.service.d
        cat > /etc/systemd/system/systemd-logind.service.d/hibernado-override.conf << EOF
[Service]
Environment=SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1
EOF
        systemctl daemon-reload
        
        log "Setting up Bluetooth fix for resume..."
        mkdir -p /home/deck/.local/bin
        cat > /home/deck/.local/bin/fix-bluetooth.sh << 'EOF'
#!/bin/bash
PATH=/sbin:/usr/sbin:/bin:/usr/bin

is_bluetooth_ok() {
    echo "Checking Bluetooth status..."
    bluetoothctl discoverable on
    if [ $? -ne 0 ]; then
        echo "Bluetooth is misbehaving."
        return 1
    else
        echo "Bluetooth is working fine."
        return 0
    fi
}

sleep 2

if ! is_bluetooth_ok; then
    (echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/unbind ; sleep 1 && echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/bind)
fi
EOF
        chmod +x /home/deck/.local/bin/fix-bluetooth.sh
        chown deck:deck /home/deck/.local/bin/fix-bluetooth.sh
        
        log "Creating Bluetooth fix systemd service..."
        cat > /etc/systemd/system/fix-bluetooth-resume.service << EOF
[Unit]
Description=Fix Bluetooth after resume from hibernation
After=hibernate.target hybrid-sleep.target suspend-then-hibernate.target bluetooth.service

[Service]
Type=oneshot
ExecStart=/home/deck/.local/bin/fix-bluetooth.sh

[Install]
WantedBy=hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF
        systemctl daemon-reload
        systemctl enable fix-bluetooth-resume.service
        
        # 7. Configure sleep.conf for suspend-then-hibernate (60 min default)
        log "Configuring suspend-then-hibernate timing..."
        cat > /etc/systemd/sleep.conf << EOF
# hibernado plugin - suspend-then-hibernate configuration
[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=60min
EOF
        systemctl daemon-reload
        
        log "Creating hibernate resume setup script in /home..."
        mkdir -p /home/deck/.local/libexec
        cat > /home/deck/.local/libexec/hibernado-set-resume.sh << 'EOF'
#!/bin/bash
# hibernado - Set resume parameters before hibernation

SWAP=/home/swapfile

if [ ! -f "$SWAP" ]; then
    echo "[hibernado] Swapfile not found, skipping resume setup" >&2
    exit 0
fi

# Get device information
DEV_PATH=$(findmnt -no SOURCE -T /home 2>/dev/null)
if [ -z "$DEV_PATH" ]; then
    echo "[hibernado] Could not find /home device" >&2
    exit 1
fi

# Get major:minor device numbers
MAJOR=$(stat -c "%t" "$DEV_PATH" 2>/dev/null)
MINOR=$(stat -c "%T" "$DEV_PATH" 2>/dev/null)

if [ -z "$MAJOR" ] || [ -z "$MINOR" ]; then
    echo "[hibernado] Could not get device numbers" >&2
    exit 1
fi

# Convert hex to decimal
MAJOR_DEC=$((16#$MAJOR))
MINOR_DEC=$((16#$MINOR))
RESUME_DEV="$MAJOR_DEC:$MINOR_DEC"

# Get swapfile offset
OFF=$(filefrag -v "$SWAP" 2>/dev/null | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')

if [ -z "$OFF" ]; then
    echo "[hibernado] Could not get swapfile offset" >&2
    exit 1
fi

# Set resume parameters
echo "[hibernado] Setting resume device: $RESUME_DEV, offset: $OFF" >&2
echo "$RESUME_DEV" > /sys/power/resume 2>/dev/null || echo "[hibernado] WARNING: Could not set resume device" >&2
echo "$OFF" > /sys/power/resume_offset 2>/dev/null || echo "[hibernado] WARNING: Could not set resume offset" >&2

# Set hibernation mode
echo "platform" > /sys/power/disk 2>/dev/null || echo "[hibernado] WARNING: Could not set hibernation mode" >&2
EOF
        chmod +x /home/deck/.local/libexec/hibernado-set-resume.sh
        chown deck:deck /home/deck/.local/libexec/hibernado-set-resume.sh
        
        log "Creating systemd service to set resume parameters before hibernation..."
        mkdir -p /etc/systemd/system/systemd-hibernate.service.d
        cat > /etc/systemd/system/systemd-hibernate.service.d/hibernado-resume.conf << EOF
[Service]
ExecStartPre=/home/deck/.local/libexec/hibernado-set-resume.sh
ExecStartPost=-/home/deck/.local/bin/fix-bluetooth.sh
ExecStartPost=-/usr/bin/steamos-bootconf set-mode booted
EOF
        
        mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
        cat > /etc/systemd/system/systemd-suspend-then-hibernate.service.d/hibernado-resume.conf << EOF
[Service]
ExecStartPre=/home/deck/.local/libexec/hibernado-set-resume.sh
ExecStartPost=-/home/deck/.local/bin/fix-bluetooth.sh
ExecStartPost=-/usr/bin/steamos-bootconf set-mode booted
EOF
        systemctl daemon-reload
        
        log "Setting up SteamOS boot counter fix..."
        cat > /etc/systemd/system/steamos-hibernate-success.service << 'EOF'
[Unit]
Description=Mark hibernation resume as successful boot
After=hibernate.target hybrid-sleep.target suspend-then-hibernate.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/bin/steamos-bootconf set-mode booted
RemainAfterExit=yes

[Install]
WantedBy=hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF
        systemctl daemon-reload
        systemctl enable steamos-hibernate-success.service 2>/dev/null || log "Note: steamos-bootconf may not be available on this system"
        
        log "Hibernation setup complete!"
        echo "SUCCESS:$UUID:$OFF"
        ;;
        
    hibernate)
        log "Preparing to hibernate..."
        
        # Get UUID and offset for resume
        UUID=$(findmnt -no UUID -T /home)
        SWAP=/home/swapfile
        OFF=$(filefrag -v "$SWAP" | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')
        
        if [ -z "$UUID" ] || [ -z "$OFF" ]; then
            log "ERROR: Could not determine resume parameters"
            echo "ERROR: Missing UUID or offset" >&2
            exit 1
        fi
        
        DEV_PATH=$(findmnt -no SOURCE -T /home)
        MAJOR=$(stat -c "%t" "$DEV_PATH" 2>/dev/null)
        MINOR=$(stat -c "%T" "$DEV_PATH" 2>/dev/null)
        
        if [ -z "$MAJOR" ] || [ -z "$MINOR" ]; then
            log "ERROR: Could not determine device numbers"
            echo "ERROR: Missing device numbers" >&2
            exit 1
        fi
        
        # Convert hex to decimal and write to /sys/power/resume
        MAJOR_DEC=$((16#$MAJOR))
        MINOR_DEC=$((16#$MINOR))
        RESUME_DEV="$MAJOR_DEC:$MINOR_DEC"
        
        log "Setting resume device to $RESUME_DEV (offset: $OFF)"
        echo "$RESUME_DEV" > /sys/power/resume 2>/dev/null || log "WARNING: Could not set resume device"
        echo "$OFF" > /sys/power/resume_offset 2>/dev/null || log "WARNING: Could not set resume offset"
        
        log "Syncing filesystems..."
        sync
        
        log "Triggering hibernation..."
        echo disk > /sys/power/state
        ;;
        
    suspend-then-hibernate)
        systemctl suspend-then-hibernate
        ;;
        
    set-power-button)
        # Usage: set-power-button enable hibernate|suspend-then-hibernate
        #        set-power-button disable
        POWER_ACTION="${2:-}"
        MODE="${3:-}"
        
        SYMLINK_PATH="/etc/systemd/system/systemd-suspend.service"
        
        if [ "$POWER_ACTION" = "enable" ]; then
            if [ -z "$MODE" ]; then
                log "ERROR: Mode not specified (hibernate or suspend-then-hibernate)"
                echo "ERROR: Mode required for enable" >&2
                exit 1
            fi
            
            # Remove existing symlink if present
            if [ -L "$SYMLINK_PATH" ] || [ -e "$SYMLINK_PATH" ]; then
                log "Removing existing systemd-suspend.service..."
                rm -f "$SYMLINK_PATH"
            fi
            
            # Create the appropriate symlink based on mode
            if [ "$MODE" = "hibernate" ]; then
                log "Creating symlink for immediate hibernate on power button..."
                ln -s /usr/lib/systemd/system/systemd-hibernate.service "$SYMLINK_PATH"
                log "Power button will now trigger immediate hibernation"
            elif [ "$MODE" = "suspend-then-hibernate" ]; then
                log "Creating symlink for suspend-then-hibernate on power button..."
                ln -s /usr/lib/systemd/system/systemd-suspend-then-hibernate.service "$SYMLINK_PATH"
                log "Power button will now trigger suspend-then-hibernate"
            else
                log "ERROR: Invalid mode '$MODE' (must be hibernate or suspend-then-hibernate)"
                echo "ERROR: Invalid mode" >&2
                exit 1
            fi
            
            systemctl daemon-reload
            log "Power button override enabled successfully"
            
        elif [ "$POWER_ACTION" = "disable" ]; then
            if [ -L "$SYMLINK_PATH" ] || [ -e "$SYMLINK_PATH" ]; then
                log "Removing power button override symlink..."
                rm -f "$SYMLINK_PATH"
                systemctl daemon-reload
                log "Power button restored to normal suspend behavior"
            else
                log "No power button override was active"
            fi
        else
            log "ERROR: Invalid action '$POWER_ACTION' (must be enable or disable)"
            echo "ERROR: Invalid action" >&2
            exit 1
        fi
        ;;
        
    cleanup)
        SWAP=/home/swapfile
        
        log "Cleaning up hibernation configuration..."
        
        # Remove low battery monitor if present
        log "Removing low battery monitor..."
        systemctl stop hibernado-battery-monitor.service 2>/dev/null || true
        systemctl disable hibernado-battery-monitor.service 2>/dev/null || true
        rm -f /etc/systemd/system/hibernado-battery-monitor.service
        rm -f /home/deck/.local/libexec/hibernado-battery-monitor.sh
        
        # Remove power button override if present
        SYMLINK_PATH="/etc/systemd/system/systemd-suspend.service"
        if [ -L "$SYMLINK_PATH" ] || [ -e "$SYMLINK_PATH" ]; then
            log "Removing power button override..."
            rm -f "$SYMLINK_PATH"
        fi
        
        if [ -f /etc/default/grub.d/hibernado.cfg ]; then
            log "Removing GRUB hibernation config..."
            rm -f /etc/default/grub.d/hibernado.cfg
            rmdir /etc/default/grub.d 2>/dev/null || true
            log "Rebuilding GRUB configuration..."
            if ! update-grub 2>&1; then
                log "WARNING: update-grub failed"
                echo "NOTE: Please run 'sudo update-grub' manually" >&2
            else
                log "GRUB configuration updated successfully"
            fi
        fi
        
        if [ -f /etc/systemd/system/systemd-logind.service.d/hibernado-override.conf ]; then
            log "Removing systemd-logind override..."
            rm -f /etc/systemd/system/systemd-logind.service.d/hibernado-override.conf
            rmdir /etc/systemd/system/systemd-logind.service.d 2>/dev/null || true
        fi
        
        log "Removing Bluetooth fix service..."
        systemctl disable fix-bluetooth-resume.service 2>/dev/null || true
        rm -f /etc/systemd/system/fix-bluetooth-resume.service
        rm -f /home/deck/.local/bin/fix-bluetooth.sh
        rmdir /home/deck/.local/bin 2>/dev/null || true
        
        log "Removing SteamOS boot counter fix service..."
        systemctl disable steamos-hibernate-success.service 2>/dev/null || true
        rm -f /etc/systemd/system/steamos-hibernate-success.service
        
        if [ -f /etc/systemd/sleep.conf ]; then
            log "Removing sleep configuration..."
            rm -f /etc/systemd/sleep.conf
        fi
        
        if [ -d /etc/systemd/system/systemd-hibernate.service.d ]; then
            log "Removing hibernate service drop-in..."
            rm -f /etc/systemd/system/systemd-hibernate.service.d/hibernado-resume.conf
            rmdir /etc/systemd/system/systemd-hibernate.service.d 2>/dev/null || true
        fi
        
        if [ -d /etc/systemd/system/systemd-suspend-then-hibernate.service.d ]; then
            log "Removing suspend-then-hibernate service drop-in..."
            rm -f /etc/systemd/system/systemd-suspend-then-hibernate.service.d/hibernado-resume.conf
            rmdir /etc/systemd/system/systemd-suspend-then-hibernate.service.d 2>/dev/null || true
        fi
        
        if [ -f /home/deck/.local/libexec/hibernado-set-resume.sh ]; then
            log "Removing resume setup script..."
            rm -f /home/deck/.local/libexec/hibernado-set-resume.sh
            rmdir /home/deck/.local/libexec 2>/dev/null || true
        fi
        
        log "Reloading systemd configuration..."
        systemctl daemon-reload
        
        if [ -f /etc/systemd/system/home-swapfile.swap ]; then
            log "Removing systemd swap unit..."
            systemctl disable home-swapfile.swap 2>/dev/null || true
            systemctl stop home-swapfile.swap 2>/dev/null || true
            rm -f /etc/systemd/system/home-swapfile.swap
        fi
        
        if swapon --show=NAME | grep -q "$SWAP"; then
            log "Deactivating swapfile..."
            swapoff "$SWAP" 2>&1 || log "WARNING: Failed to deactivate swapfile"
        fi
        
        if [ -f "$SWAP" ]; then
            log "Removing swapfile..."
            rm -f "$SWAP" 2>&1 || log "WARNING: Failed to remove swapfile"
        fi
        
        log "Cleanup complete. All hibernation configuration has been removed."
        log "NOTE: A reboot is recommended to ensure all kernel parameters are reset."
        ;;
    
    get-delay)
        # Get current hibernate delay setting from sleep.conf
        if [ -f /etc/systemd/sleep.conf ]; then
            # Extract the delay value (strip 'min' suffix and get the number)
            DELAY=$(grep "^HibernateDelaySec=" /etc/systemd/sleep.conf | cut -d'=' -f2 | sed 's/min$//')
            if [ -n "$DELAY" ]; then
                echo "$DELAY"
                exit 0
            fi
        fi
        # Default to 60 if not found
        echo "60"
        exit 0
        ;;
    
    set-delay)
        # Set hibernate delay: $2 = delay in minutes
        if [ -z "$2" ]; then
            log "ERROR: Delay minutes not specified"
            exit 1
        fi
        
        DELAY_MIN="$2"
        
        if ! [[ "$DELAY_MIN" =~ ^[0-9]+$ ]]; then
            log "ERROR: Invalid delay value (must be a number)"
            exit 1
        fi
        
        log "Setting hibernate delay to $DELAY_MIN minutes..."
        
        # Update sleep.conf with new delay
        cat > /etc/systemd/sleep.conf << EOF
# hibernado plugin - suspend-then-hibernate configuration
[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=${DELAY_MIN}min
EOF
        
        systemctl daemon-reload
        log "Hibernate delay set to $DELAY_MIN minutes"
        exit 0
        ;;
    
    set-low-battery-hibernate)
        # Enable or disable low battery hibernate: $2 = enable|disable, $3 = threshold (default 5)
        ACTION="${2:-}"
        THRESHOLD="${3:-5}"
        
        if [ "$ACTION" = "enable" ]; then
            log "Setting up low battery hibernate at ${THRESHOLD}%..."
            
            # Create the battery monitor script
            mkdir -p /home/deck/.local/libexec
            cat > /home/deck/.local/libexec/hibernado-battery-monitor.sh << 'BATTERYSCRIPT'
#!/bin/bash
# Hibernado low battery monitor
# Checks battery level and hibernates if below threshold

THRESHOLD=${1:-5}
CHECK_INTERVAL=60

log() {
    echo "[hibernado-battery] $(date '+%Y-%m-%d %H:%M:%S') $1" | systemd-cat -t hibernado-battery -p info
}

get_battery_level() {
    if [ -f /sys/class/power_supply/BAT1/capacity ]; then
        cat /sys/class/power_supply/BAT1/capacity
    elif [ -f /sys/class/power_supply/BAT0/capacity ]; then
        cat /sys/class/power_supply/BAT0/capacity
    else
        echo "100"  # Default to 100 if no battery found
    fi
}

is_charging() {
    local status=""
    if [ -f /sys/class/power_supply/BAT1/status ]; then
        status=$(cat /sys/class/power_supply/BAT1/status)
    elif [ -f /sys/class/power_supply/BAT0/status ]; then
        status=$(cat /sys/class/power_supply/BAT0/status)
    fi
    
    if [ "$status" = "Charging" ] || [ "$status" = "Full" ]; then
        return 0
    fi
    return 1
}

log "Starting battery monitor with threshold ${THRESHOLD}%"

while true; do
    LEVEL=$(get_battery_level)
    
    if ! is_charging && [ "$LEVEL" -le "$THRESHOLD" ]; then
        log "Battery at ${LEVEL}% (threshold: ${THRESHOLD}%), initiating hibernate..."
        
        # Use systemctl to trigger hibernate (this will use our configured service with all fixes)
        systemctl hibernate
        
        # If we wake up from hibernate, wait a bit before checking again
        sleep 30
    fi
    
    sleep $CHECK_INTERVAL
done
BATTERYSCRIPT
            chmod +x /home/deck/.local/libexec/hibernado-battery-monitor.sh
            chown deck:deck /home/deck/.local/libexec/hibernado-battery-monitor.sh
            
            # Create the systemd service
            cat > /etc/systemd/system/hibernado-battery-monitor.service << EOF
[Unit]
Description=Hibernado Low Battery Monitor
After=multi-user.target

[Service]
Type=simple
ExecStart=/home/deck/.local/libexec/hibernado-battery-monitor.sh ${THRESHOLD}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
            
            systemctl daemon-reload
            systemctl enable hibernado-battery-monitor.service
            systemctl restart hibernado-battery-monitor.service
            
            log "Low battery hibernate enabled at ${THRESHOLD}%"
            echo "ENABLED:${THRESHOLD}"
            exit 0
            
        elif [ "$ACTION" = "disable" ]; then
            log "Disabling low battery hibernate..."
            
            systemctl stop hibernado-battery-monitor.service 2>/dev/null || true
            systemctl disable hibernado-battery-monitor.service 2>/dev/null || true
            rm -f /etc/systemd/system/hibernado-battery-monitor.service
            rm -f /home/deck/.local/libexec/hibernado-battery-monitor.sh
            systemctl daemon-reload
            
            log "Low battery hibernate disabled"
            echo "DISABLED"
            exit 0
        else
            log "ERROR: Invalid action '$ACTION' (must be enable or disable)"
            echo "ERROR: Invalid action" >&2
            exit 1
        fi
        ;;
    
    get-low-battery-status)
        # Check if low battery hibernate is enabled and get threshold
        if systemctl is-enabled hibernado-battery-monitor.service 2>/dev/null | grep -q "enabled"; then
            # Try to extract threshold from service file
            if [ -f /etc/systemd/system/hibernado-battery-monitor.service ]; then
                THRESHOLD=$(grep "ExecStart=" /etc/systemd/system/hibernado-battery-monitor.service | grep -oP '\d+$' || echo "5")
                echo "ENABLED:${THRESHOLD}"
            else
                echo "ENABLED:5"
            fi
        else
            echo "DISABLED"
        fi
        exit 0
        ;;
        
    *)
        echo "Usage: $0 {status|prepare|hibernate|suspend-then-hibernate|set-power-button|get-delay|set-delay|set-low-battery-hibernate|get-low-battery-status|cleanup}"
        exit 1
        ;;
esac

