#!/usr/bin/env bash
# ==============================================================================
# Eternal Summer ☀️ - Ultra-Low Latency GUI Prioritization & Anti-Freeze Setup
#
# Designed for KDE Plasma (Wayland/X11) on Ubuntu / Debian / KDE neon
# Fully reproducible, standalone script to prevent desktop freezing under
# heavy CPU, Memory, Swap, or Disk I/O load.
#
# Usage:
#   sudo ./eternal_summer.sh [install|uninstall|status]
#        ./eternal_summer.sh add <app_name> [nice_level] [oom_score_adj]
#        ./eternal_summer.sh remove <app_name>
#        ./eternal_summer.sh list
#        ./eternal_summer.sh status
# ==============================================================================
set -euo pipefail

# ANSI color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Priority configuration locations
CONFIG_DIR_GLOBAL="/etc/eternal_summer"
CONFIG_GLOBAL="/etc/eternal_summer/priority_apps.conf"
CONFIG_DIR_USER="${XDG_CONFIG_HOME:-$HOME/.config}/eternal_summer"
CONFIG_USER="${CONFIG_DIR_USER}/priority_apps.conf"

GUI_PROCS=("kwin_wayland" "kwin_x11" "plasmashell" "Xwayland" "pipewire" "wireplumber" "kwin_wayland_wrapper")
BATCH_PROCS=("cc1" "cc1plus" "clang" "clang++" "rustc" "cargo" "ninja" "make" "ld" "gold" "mold" "lld" "x264" "x265" "ffmpeg" "blender" "optipng")

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERR]${NC}  $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This action requires root privileges."
        echo "Please run: sudo $0 $1"
        exit 1
    fi
}

detect_target_user() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER=$(id -un 1000 2>/dev/null || who | awk '{print $1}' | head -n 1 || echo "")
    fi

    if [[ -z "$TARGET_USER" ]]; then
        TARGET_HOME=""
        TARGET_UID=""
        TARGET_GID=""
    else
        TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
        TARGET_UID=$(id -u "$TARGET_USER")
        TARGET_GID=$(id -g "$TARGET_USER")
    fi
}

get_writable_config() {
    if [[ $EUID -eq 0 ]]; then
        mkdir -p "$CONFIG_DIR_GLOBAL"
        echo "$CONFIG_GLOBAL"
    elif [[ -w "$CONFIG_DIR_GLOBAL" || ( -f "$CONFIG_GLOBAL" && -w "$CONFIG_GLOBAL" ) ]]; then
        echo "$CONFIG_GLOBAL"
    else
        mkdir -p "$CONFIG_DIR_USER"
        echo "$CONFIG_USER"
    fi
}

wait_for_apt_locks() {
    local max_wait=40
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        if [[ $waited -ge $max_wait ]]; then
            log_warn "Apt locks still held after ${max_wait}s. Proceeding anyway..."
            break
        fi
        log_info "Waiting for background package managers to finish (${waited}s)..."
        sleep 2
        waited=$((waited + 2))
    done
}

# ------------------------------------------------------------------------------
# App Priority Management: add, remove, list
# ------------------------------------------------------------------------------

apply_app_priority() {
    local app="$1"
    local target_nice="${2:--10}"
    local target_oom="${3:--500}"

    local pids
    pids=$(pgrep -x "$app" 2>/dev/null || true)
    if [[ -z "$pids" ]]; then
        pids=$(pgrep -f "$app" 2>/dev/null | grep -v "$$" || true)
    fi

    if [[ -n "$pids" ]]; then
        for p in $pids; do
            [[ -z "$p" || "$p" -le 2 ]] && continue
            renice -n "$target_nice" -p "$p" &>/dev/null || true
            ionice -c 1 -n 0 -p "$p" &>/dev/null || ionice -c 2 -n 0 -p "$p" &>/dev/null || true
            if [[ $EUID -eq 0 ]]; then
                echo "$target_oom" > "/proc/$p/oom_score_adj" 2>/dev/null || true
            fi
        done
        local count
        count=$(echo "$pids" | wc -w)
        log_info "Applied priority to currently running '$app' (${count} process(es), PID(s): $(echo $pids | tr '\n' ' '))"
    else
        log_info "'$app' is not currently running. The Priority Guard daemon will automatically boost it upon launch."
    fi
}

reset_app_priority() {
    local app="$1"
    local pids
    pids=$(pgrep -x "$app" 2>/dev/null || true)
    if [[ -z "$pids" ]]; then
        pids=$(pgrep -f "$app" 2>/dev/null | grep -v "$$" || true)
    fi

    if [[ -n "$pids" ]]; then
        for p in $pids; do
            [[ -z "$p" || "$p" -le 2 ]] && continue
            renice -n 0 -p "$p" &>/dev/null || true
            ionice -c 2 -n 4 -p "$p" &>/dev/null || true
            if [[ $EUID -eq 0 ]]; then
                echo 0 > "/proc/$p/oom_score_adj" 2>/dev/null || true
            fi
        done
        log_info "Reset priority of running instances of '$app' back to normal (Nice 0, OOM 0)"
    fi
}

add_app() {
    local app="${1:-}"
    local target_nice="${2:--10}"
    local target_oom="${3:--500}"

    if [[ -z "$app" ]]; then
        log_error "Application name is required."
        echo "Usage: $0 add <app_name> [nice_level] [oom_score_adj]"
        echo "Example: $0 add konsole"
        echo "Example: $0 add steam -12 -600"
        exit 1
    fi

    if ! [[ "$target_nice" =~ ^-?[0-9]+$ ]] || (( target_nice < -20 || target_nice > 19 )); then
        log_error "Invalid nice level: $target_nice (must be an integer between -20 and 19)"
        exit 1
    fi

    if ! [[ "$target_oom" =~ ^-?[0-9]+$ ]] || (( target_oom < -1000 || target_oom > 1000 )); then
        log_error "Invalid OOM score adjust: $target_oom (must be an integer between -1000 and 1000)"
        exit 1
    fi

    local conf_file
    conf_file=$(get_writable_config)
    mkdir -p "$(dirname "$conf_file")"
    touch "$conf_file"

    # Remove existing entry if present
    grep -v -E "^[[:space:]]*${app}([[:space:]]|$)" "$conf_file" > "${conf_file}.tmp" 2>/dev/null || true
    mv "${conf_file}.tmp" "$conf_file"

    # Append updated rule
    echo "$app $target_nice $target_oom" >> "$conf_file"
    log_success "Added '$app' to priority list in $conf_file (Nice: $target_nice, OOM: $target_oom)"

    # Immediately apply to any running instances
    apply_app_priority "$app" "$target_nice" "$target_oom"
}

remove_app() {
    local app="${1:-}"
    if [[ -z "$app" ]]; then
        log_error "Application name is required."
        echo "Usage: $0 remove <app_name>"
        exit 1
    fi

    local found=0
    for conf_file in "$CONFIG_GLOBAL" "$CONFIG_USER"; do
        if [[ -f "$conf_file" ]] && grep -q -E "^[[:space:]]*${app}([[:space:]]|$)" "$conf_file"; then
            grep -v -E "^[[:space:]]*${app}([[:space:]]|$)" "$conf_file" > "${conf_file}.tmp" || true
            mv "${conf_file}.tmp" "$conf_file"
            log_success "Removed '$app' from $conf_file"
            found=1
        fi
    done

    if [[ $found -eq 0 ]]; then
        log_warn "'$app' was not found in any priority configuration."
    else
        reset_app_priority "$app"
    fi
}

list_apps() {
    echo -e "\n${BOLD}=== Eternal Summer Priority Applications ===${NC}\n"

    echo -e "${BOLD}${CYAN}Core Desktop Environment Components (Built-in):${NC}"
    printf "  %-22s %-12s %-12s %-20s\n" "PROCESS" "PRIORITY" "OOM SHIELD" "LIVE STATUS"
    echo "  ----------------------------------------------------------------------------------"
    for proc in "${GUI_PROCS[@]}"; do
        local pids
        pids=$(pgrep -x "$proc" 2>/dev/null || true)
        local status="Not Running"
        if [[ -n "$pids" ]]; then
            local first_pid
            first_pid=$(echo "$pids" | head -n 1)
            local ni
            ni=$(ps -p "$first_pid" -o nice= 2>/dev/null | tr -d ' ' || echo 'N/A')
            local oom
            oom=$(cat "/proc/$first_pid/oom_score_adj" 2>/dev/null || echo 'N/A')
            local count
            count=$(echo "$pids" | wc -w)
            status="${GREEN}Running (${count} proc, PID ${first_pid}, Nice=${ni}, OOM=${oom})${NC}"
        fi
        local default_nice="-10"
        [[ "$proc" =~ kwin ]] && default_nice="-15"
        printf "  %-22s %-12s %-12s " "$proc" "Nice ${default_nice}" "OOM -500"
        echo -e "$status"
    done

    echo -e "\n${BOLD}${CYAN}Custom Prioritized Applications:${NC}"
    printf "  %-22s %-12s %-12s %-20s\n" "APPLICATION" "TARGET NICE" "TARGET OOM" "LIVE STATUS"
    echo "  ----------------------------------------------------------------------------------"

    local custom_count=0
    local seen_apps=()
    for conf_file in "$CONFIG_GLOBAL" "$CONFIG_USER"; do
        [[ -f "$conf_file" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=$(echo "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            [[ -z "$line" ]] && continue
            read -r app nice_val oom_val <<< "$line"
            nice_val="${nice_val:--10}"
            oom_val="${oom_val:--500}"

            if [[ " ${seen_apps[*]:-} " =~ " ${app} " ]]; then
                continue
            fi
            seen_apps+=("$app")
            custom_count=$((custom_count + 1))

            local pids
            pids=$(pgrep -x "$app" 2>/dev/null || pgrep -f "$app" 2>/dev/null | grep -v "$$" || true)
            local status="${YELLOW}Not Running${NC}"
            if [[ -n "$pids" ]]; then
                local first_pid
                first_pid=$(echo "$pids" | head -n 1)
                local cur_ni
                cur_ni=$(ps -p "$first_pid" -o nice= 2>/dev/null | tr -d ' ' || echo 'N/A')
                local cur_oom
                cur_oom=$(cat "/proc/$first_pid/oom_score_adj" 2>/dev/null || echo 'N/A')
                local count
                count=$(echo "$pids" | wc -w)
                status="${GREEN}Running (${count} proc, PID ${first_pid}, Nice=${cur_ni}, OOM=${cur_oom})${NC}"
            fi

            printf "  %-22s %-12s %-12s " "$app" "Nice ${nice_val}" "OOM ${oom_val}"
            echo -e "$status"
        done < "$conf_file"
    done

    if [[ $custom_count -eq 0 ]]; then
        echo -e "  ${YELLOW}(No custom applications added yet. Use '$0 add <app_name>' to prioritize an app.)${NC}"
    fi
    echo ""
}

show_status() {
    echo -e "\n${BOLD}=== Current GUI & System Responsiveness Status ===${NC}"

    echo -e "\n${CYAN}1. Virtual Memory & Dirty Ratios:${NC}"
    echo "  vm.dirty_bytes:           $(cat /proc/sys/vm/dirty_bytes 2>/dev/null || echo 'N/A')"
    echo "  vm.dirty_background_bytes: $(cat /proc/sys/vm/dirty_background_bytes 2>/dev/null || echo 'N/A')"
    echo "  vm.dirty_ratio:           $(cat /proc/sys/vm/dirty_ratio 2>/dev/null || echo 'N/A')%"
    echo "  vm.swappiness:            $(cat /proc/sys/vm/swappiness 2>/dev/null || echo 'N/A')"
    echo "  vm.vfs_cache_pressure:    $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo 'N/A')"
    echo "  sched_cfs_slice_us:       $(cat /proc/sys/kernel/sched_cfs_bandwidth_slice_us 2>/dev/null || echo 'N/A')"

    echo -e "\n${CYAN}2. Swap & ZRAM Status:${NC}"
    if command -v zramctl &>/dev/null && zramctl --noheadings 2>/dev/null | grep -q zram; then
        zramctl
    else
        echo "  (zramctl not active or no zram devices)"
    fi
    echo ""
    swapon --show || free -h

    echo -e "\n${CYAN}3. Anti-OOM Daemon (EarlyOOM):${NC}"
    if systemctl is-active --quiet earlyoom 2>/dev/null; then
        echo -e "  earlyoom: ${GREEN}ACTIVE${NC}"
    else
        echo -e "  earlyoom: ${YELLOW}INACTIVE / NOT INSTALLED${NC}"
    fi

    echo -e "\n${CYAN}4. GUI Priority Guard Service:${NC}"
    if systemctl is-active --quiet gui-priority-guard.service 2>/dev/null; then
        echo -e "  gui-priority-guard: ${GREEN}ACTIVE${NC}"
    else
        echo -e "  gui-priority-guard: ${YELLOW}INACTIVE / NOT INSTALLED${NC}"
    fi

    echo -e "\n${CYAN}5. Active Priorities & Applications:${NC}"
    list_apps

    echo -e "${CYAN}6. Systemd Session Slice Weight & Protection:${NC}"
    if [[ -d /sys/fs/cgroup/user.slice ]]; then
        cat /sys/fs/cgroup/user.slice/user-*.slice/user@*.service/session.slice/cpu.weight 2>/dev/null | head -n 1 | awk '{print "  session.slice cpu.weight: " $1}' || echo "  session.slice cpu.weight: default"
        cat /sys/fs/cgroup/user.slice/user-*.slice/user@*.service/session.slice/memory.low 2>/dev/null | head -n 1 | awk '{print "  session.slice memory.low: " $1 " bytes"}' || echo "  session.slice memory.low: 0"
        cat /sys/fs/cgroup/user.slice/user-*.slice/user@*.service/session.slice/memory.min 2>/dev/null | head -n 1 | awk '{print "  session.slice memory.min: " $1 " bytes"}' || echo "  session.slice memory.min: 0"
        cat /sys/fs/cgroup/user.slice/user-*.slice/user@*.service/app.slice/cpu.weight 2>/dev/null | head -n 1 | awk '{print "  app.slice cpu.weight:     " $1}' || echo "  app.slice cpu.weight: default"
    fi
    echo ""
}

install() {
    check_root "install"
    detect_target_user

    echo -e "\n${BOLD}${BLUE}================================================================${NC}"
    echo -e "${BOLD}${BLUE}   Applying Anti-Freeze & Utmost GUI Prioritization Tuning     ${NC}"
    echo -e "${BOLD}${BLUE}================================================================${NC}\n"

    # --------------------------------------------------------------------------
    # Step 1: Install prerequisites
    # --------------------------------------------------------------------------
    log_info "Step 1/8: Installing earlyoom and zram-tools via apt..."
    wait_for_apt_locks
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    wait_for_apt_locks
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq earlyoom zram-tools util-linux procps bc
    log_success "Prerequisites installed."

    # --------------------------------------------------------------------------
    # Step 2: Configure Fast Compressed In-RAM Swap (ZRAM)
    # --------------------------------------------------------------------------
    log_info "Step 2/8: Configuring high-performance ZRAM swap..."
    cat > /etc/default/zramswap << 'EOF'
# /etc/default/zramswap
# Ultra-fast compressed RAM swap to prevent disk thrashing and executable eviction
ALGO=zstd
PERCENT=100
PRIORITY=32767
EOF
    systemctl enable --now zramswap.service || true
    systemctl restart zramswap.service || true
    log_success "ZRAM swap active (100% RAM size pool, zstd compression, top priority 32767)."

    # --------------------------------------------------------------------------
    # Step 3: Configure EarlyOOM Daemon (Protect GUI, Terminate Runaway Offender)
    # --------------------------------------------------------------------------
    log_info "Step 3/8: Configuring EarlyOOM daemon..."
    cat > /etc/default/earlyoom << 'EOF'
# /etc/default/earlyoom
# Terminate runaway memory hogs before the kernel enters a multi-minute freeze.
# Explicitly protects the GUI compositor, shell, display manager, and audio server.
EARLYOOM_ARGS="-m 4 -s 10 -r 60 --avoid '(^|/)(kwin_wayland|kwin_x11|plasmashell|Xwayland|startplasma|systemd|sddm|plasmalogin|pipewire|wireplumber|dbus-daemon|systemd-logind|gui-priority-guard)$' --prefer '(^|/)(chrome|firefox|brave|webcontent|node|npm|rustc|cc1plus|clang|clang++|python.*|java|blender|ffmpeg)$'"
EOF
    systemctl restart earlyoom.service || systemctl start earlyoom.service
    systemctl enable earlyoom.service
    log_success "EarlyOOM configured and running."

    # --------------------------------------------------------------------------
    # Step 4: Kernel Sysctl Desktop Responsiveness Tuning
    # --------------------------------------------------------------------------
    log_info "Step 4/8: Applying kernel sysctl responsiveness parameters..."
    cat > /etc/sysctl.d/99-gui-responsiveness.conf << 'EOF'
# ==============================================================================
# Desktop GUI Responsiveness & Anti-Freeze sysctl tuning
# ==============================================================================

# Cap maximum unwritten dirty pages to 256MB to avoid massive I/O stalls during writes
vm.dirty_bytes = 268435456

# Start background writeback early (at 64MB) to keep I/O smooth and continuous
vm.dirty_background_bytes = 67108864

# Protect directory and inode metadata cache from aggressive eviction under load
vm.vfs_cache_pressure = 50

# Aggressively prefer swapping anonymous memory into fast ZRAM rather than discarding
# file-backed GUI code pages (prevents kwin/plasmashell code from being purged to disk)
vm.swappiness = 180

# Read 1 page at a time when swapping with ZRAM for near-zero read latency
vm.page-cluster = 0

# Prevent direct-reclaim synchronous stalls by triggering background kswapd earlier
vm.watermark_scale_factor = 125
vm.watermark_boost_factor = 0

# Desktop scheduling fairness & responsiveness
kernel.sched_autogroup_enabled = 1
kernel.sched_cfs_bandwidth_slice_us = 3000
EOF
    sysctl --system > /dev/null
    log_success "Kernel sysctl responsiveness parameters loaded."

    # --------------------------------------------------------------------------
    # Step 5: PAM Realtime & Priority Limits
    # --------------------------------------------------------------------------
    log_info "Step 5/8: Configuring PAM realtime and priority limits..."
    cat > /etc/security/limits.d/99-gui-priority.conf << 'EOF'
# Allow desktop user and administrative groups to set real-time priority and nice levels
*               soft    nice           -20
*               hard    nice           -20
*               soft    rtprio          95
*               hard    rtprio          95
*               soft    memlock         unlimited
*               hard    memlock         unlimited
root            soft    nice           -20
root            hard    nice           -20
root            soft    rtprio          95
root            hard    rtprio          95
EOF
    log_success "PAM limits updated for realtime priority."

    # --------------------------------------------------------------------------
    # Step 6: Udev Disk Scheduler Rules for Interactivity
    # --------------------------------------------------------------------------
    log_info "Step 6/8: Configuring disk I/O scheduler udev rules..."
    cat > /etc/udev/rules.d/60-gui-ioschedulers.rules << 'EOF'
# Set optimal desktop I/O schedulers:
# NVMe: none or mq-deadline
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
# SATA SSD: mq-deadline or bfq
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# Rotating HDD: bfq for smooth desktop audio/video and interactive responsiveness
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
    udevadm control --reload-rules && udevadm trigger --subsystem-match=block || true
    log_success "Udev disk scheduler rules applied."

    # --------------------------------------------------------------------------
    # Step 7: Systemd Cgroup v2 Controller Delegation & Slice Prioritization
    # --------------------------------------------------------------------------
    log_info "Step 7/8: Configuring Cgroup v2 slice weights and memory reservations..."

    # Enable controller delegation to user sessions
    mkdir -p /etc/systemd/system/user@.service.d
    cat > /etc/systemd/system/user@.service.d/delegate.conf << 'EOF'
[Service]
Delegate=cpu memory io pids
EOF

    # Elevate user.slice priority over background system services
    mkdir -p /etc/systemd/system/user.slice.d
    cat > /etc/systemd/system/user.slice.d/10-gui-priority.conf << 'EOF'
[Slice]
CPUWeight=10000
IOWeight=10000
EOF

    # Configure SYSTEM-WIDE user session drop-ins in /etc/systemd/user/
    mkdir -p /etc/systemd/user/session.slice.d
    cat > /etc/systemd/user/session.slice.d/10-gui-priority.conf << 'EOF'
[Slice]
CPUWeight=10000
IOWeight=10000
MemoryLow=1500M
MemoryMin=512M
EOF

    mkdir -p /etc/systemd/user/app.slice.d
    cat > /etc/systemd/user/app.slice.d/10-gui-priority.conf << 'EOF'
[Slice]
CPUWeight=100
IOWeight=100
EOF

    mkdir -p /etc/systemd/user/background.slice.d
    cat > /etc/systemd/user/background.slice.d/10-gui-priority.conf << 'EOF'
[Slice]
CPUWeight=1
IOWeight=1
MemoryLow=0
EOF

    mkdir -p /etc/systemd/user/plasma-kwin_wayland.service.d
    cat > /etc/systemd/user/plasma-kwin_wayland.service.d/10-gui-priority.conf << 'EOF'
[Service]
Nice=-15
CPUWeight=10000
IOWeight=10000
MemoryLow=768M
MemoryMin=256M
OOMScoreAdjust=-500
EOF

    mkdir -p /etc/systemd/user/plasma-plasmashell.service.d
    cat > /etc/systemd/user/plasma-plasmashell.service.d/10-gui-priority.conf << 'EOF'
[Service]
Nice=-10
CPUWeight=5000
IOWeight=5000
MemoryLow=512M
MemoryMin=128M
OOMScoreAdjust=-500
EOF

    # Ensure background file indexer (Baloo) is strictly deprioritized
    mkdir -p /etc/systemd/user/kde-baloo.service.d
    cat > /etc/systemd/user/kde-baloo.service.d/10-gui-priority.conf << 'EOF'
[Service]
Nice=19
CPUWeight=1
IOWeight=1
MemoryLow=0
EOF

    # Also sync into target user's ~/.config/systemd/user/ if target home exists
    if [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]]; then
        USER_SYSTEMD="$TARGET_HOME/.config/systemd/user"
        mkdir -p "$USER_SYSTEMD/session.slice.d" \
                 "$USER_SYSTEMD/app.slice.d" \
                 "$USER_SYSTEMD/background.slice.d" \
                 "$USER_SYSTEMD/plasma-kwin_wayland.service.d" \
                 "$USER_SYSTEMD/plasma-plasmashell.service.d" \
                 "$USER_SYSTEMD/kde-baloo.service.d"

        cp /etc/systemd/user/session.slice.d/10-gui-priority.conf "$USER_SYSTEMD/session.slice.d/"
        cp /etc/systemd/user/app.slice.d/10-gui-priority.conf "$USER_SYSTEMD/app.slice.d/"
        cp /etc/systemd/user/background.slice.d/10-gui-priority.conf "$USER_SYSTEMD/background.slice.d/"
        cp /etc/systemd/user/plasma-kwin_wayland.service.d/10-gui-priority.conf "$USER_SYSTEMD/plasma-kwin_wayland.service.d/"
        cp /etc/systemd/user/plasma-plasmashell.service.d/10-gui-priority.conf "$USER_SYSTEMD/plasma-plasmashell.service.d/"
        cp /etc/systemd/user/kde-baloo.service.d/10-gui-priority.conf "$USER_SYSTEMD/kde-baloo.service.d/"

        chown -R "${TARGET_USER}:${TARGET_GROUP:-$TARGET_USER}" "$USER_SYSTEMD"
        log_info "Synchronized configuration to $USER_SYSTEMD"
    fi

    # Set up global priority app config with write permissions for administrative users
    mkdir -p "$CONFIG_DIR_GLOBAL"
    touch "$CONFIG_GLOBAL"
    chmod 775 "$CONFIG_DIR_GLOBAL" 2>/dev/null || true
    chmod 664 "$CONFIG_GLOBAL" 2>/dev/null || true
    chown root:sudo "$CONFIG_DIR_GLOBAL" "$CONFIG_GLOBAL" 2>/dev/null || true

    systemctl daemon-reload

    # Reload active user systemd instance if running
    if [[ -n "${TARGET_UID:-}" && -d "/run/user/${TARGET_UID}" ]]; then
        su - "$TARGET_USER" -c "systemctl --user daemon-reload" 2>/dev/null || \
        runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="/run/user/$TARGET_UID" systemctl --user daemon-reload 2>/dev/null || true
    fi

    log_success "Cgroup v2 slices and systemd drop-ins configured."

    # --------------------------------------------------------------------------
    # Step 8: Install and Start Dynamic GUI Priority Guard Daemon
    # --------------------------------------------------------------------------
    log_info "Step 8/8: Installing dynamic GUI Priority Guard service..."

    cat > /usr/local/bin/gui-priority-guard.sh << 'EOF'
#!/usr/bin/env bash
# Continuous guard that keeps GUI compositor/shell and custom priority apps boosted
# and automatically drops the priority of heavy batch/build workloads.
set -u

GUI_PROCS=("kwin_wayland" "kwin_x11" "plasmashell" "Xwayland" "pipewire" "wireplumber" "kwin_wayland_wrapper")
BATCH_PROCS=("cc1" "cc1plus" "clang" "clang++" "rustc" "cargo" "ninja" "make" "ld" "gold" "mold" "lld" "x264" "x265" "ffmpeg" "blender" "optipng")

while true; do
    # 1. Enforce elevated priority for core desktop components
    for proc in "${GUI_PROCS[@]}"; do
        pids=$(pgrep -x "$proc" || true)
        for p in $pids; do
            [[ -z "$p" ]] && continue
            
            target_nice=-10
            if [[ "$proc" == "kwin_wayland" || "$proc" == "kwin_x11" || "$proc" == "kwin_wayland_wrapper" ]]; then
                target_nice=-15
            fi

            cur_nice=$(ps -p "$p" -o nice= 2>/dev/null | tr -d ' ' || echo "")
            if [[ -n "$cur_nice" && "$cur_nice" -gt "$target_nice" ]]; then
                renice -n "$target_nice" -p "$p" &>/dev/null || true
            fi

            # Realtime / Best-effort high IO priority
            ionice -c 1 -n 0 -p "$p" &>/dev/null || ionice -c 2 -n 0 -p "$p" &>/dev/null || true

            # Shield GUI from kernel OOM killer
            cur_oom=$(cat "/proc/$p/oom_score_adj" 2>/dev/null || echo "")
            if [[ -n "$cur_oom" && "$cur_oom" -gt -500 ]]; then
                echo -500 > "/proc/$p/oom_score_adj" 2>/dev/null || true
            fi
        done
    done

    # 2. Enforce priority on custom user-defined applications
    for cfile in /etc/eternal_summer/priority_apps.conf /home/*/.config/eternal_summer/priority_apps.conf; do
        [[ -f "$cfile" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=$(echo "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            [[ -z "$line" ]] && continue
            read -r c_app c_nice c_oom <<< "$line"
            c_nice="${c_nice:--10}"
            c_oom="${c_oom:--500}"

            c_pids=$(pgrep -x "$c_app" 2>/dev/null || true)
            if [[ -z "$c_pids" ]]; then
                c_pids=$(pgrep -f "$c_app" 2>/dev/null | grep -v "$$" || true)
            fi

            for cp in $c_pids; do
                [[ -z "$cp" || "$cp" -le 2 ]] && continue
                cur_cnice=$(ps -p "$cp" -o nice= 2>/dev/null | tr -d ' ' || echo "")
                if [[ -n "$cur_cnice" && "$cur_cnice" -gt "$c_nice" ]]; then
                    renice -n "$c_nice" -p "$cp" &>/dev/null || true
                fi
                ionice -c 1 -n 0 -p "$cp" &>/dev/null || ionice -c 2 -n 0 -p "$cp" &>/dev/null || true
                cur_coom=$(cat "/proc/$cp/oom_score_adj" 2>/dev/null || echo "")
                if [[ -n "$cur_coom" && "$cur_coom" -gt "$c_oom" ]]; then
                    echo "$c_oom" > "/proc/$cp/oom_score_adj" 2>/dev/null || true
                fi
            done
        done < "$cfile"
    done

    # 3. Automatically deprioritize heavy batch and build workloads
    for bproc in "${BATCH_PROCS[@]}"; do
        bpids=$(pgrep -x "$bproc" || true)
        for bp in $bpids; do
            [[ -z "$bp" ]] && continue
            cur_bnice=$(ps -p "$bp" -o nice= 2>/dev/null | tr -d ' ' || echo "")
            if [[ -n "$cur_bnice" && "$cur_bnice" -lt 15 ]]; then
                renice -n 15 -p "$bp" &>/dev/null || true
            fi
            ionice -c 3 -p "$bp" &>/dev/null || ionice -c 2 -n 7 -p "$bp" &>/dev/null || true
        done
    done

    sleep 5
done
EOF
    chmod +x /usr/local/bin/gui-priority-guard.sh

    cat > /etc/systemd/system/gui-priority-guard.service << 'EOF'
[Unit]
Description=GUI Priority and Anti-Freeze Guard Daemon
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gui-priority-guard.sh
Restart=always
RestartSec=3
Nice=-15
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now gui-priority-guard.service
    log_success "GUI Priority Guard daemon active and running."

    # Immediate one-time priority boost for existing processes
    /usr/local/bin/gui-priority-guard.sh &
    GUARD_PID=$!
    sleep 1
    kill $GUARD_PID 2>/dev/null || true

    echo -e "\n${BOLD}${GREEN}================================================================${NC}"
    echo -e "${BOLD}${GREEN}   Success! Your system is now optimized for zero GUI freezes.  ${NC}"
    echo -e "${BOLD}${GREEN}================================================================${NC}\n"
    show_status
}

uninstall() {
    check_root "uninstall"
    detect_target_user
    log_info "Reverting GUI prioritization optimizations..."

    systemctl stop gui-priority-guard.service 2>/dev/null || true
    systemctl disable gui-priority-guard.service 2>/dev/null || true
    rm -f /etc/systemd/system/gui-priority-guard.service /usr/local/bin/gui-priority-guard.sh

    rm -f /etc/sysctl.d/99-gui-responsiveness.conf
    sysctl --system > /dev/null

    rm -f /etc/security/limits.d/99-gui-priority.conf
    rm -f /etc/udev/rules.d/60-gui-ioschedulers.rules
    udevadm control --reload-rules || true

    rm -f /etc/systemd/system/user.slice.d/10-gui-priority.conf
    rm -f /etc/systemd/system/user@.service.d/delegate.conf
    rm -rf /etc/systemd/user/session.slice.d/10-gui-priority.conf
    rm -rf /etc/systemd/user/app.slice.d/10-gui-priority.conf
    rm -rf /etc/systemd/user/background.slice.d/10-gui-priority.conf
    rm -rf /etc/systemd/user/plasma-kwin_wayland.service.d/10-gui-priority.conf
    rm -rf /etc/systemd/user/plasma-plasmashell.service.d/10-gui-priority.conf
    rm -rf /etc/systemd/user/kde-baloo.service.d/10-gui-priority.conf
    rm -rf "$CONFIG_DIR_GLOBAL"

    if [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]]; then
        rm -f "$TARGET_HOME/.config/systemd/user/session.slice.d/10-gui-priority.conf" \
              "$TARGET_HOME/.config/systemd/user/app.slice.d/10-gui-priority.conf" \
              "$TARGET_HOME/.config/systemd/user/background.slice.d/10-gui-priority.conf" \
              "$TARGET_HOME/.config/systemd/user/plasma-kwin_wayland.service.d/10-gui-priority.conf" \
              "$TARGET_HOME/.config/systemd/user/plasma-plasmashell.service.d/10-gui-priority.conf" \
              "$TARGET_HOME/.config/systemd/user/kde-baloo.service.d/10-gui-priority.conf"
    fi

    systemctl daemon-reload
    log_success "All customizations reverted."
}

# ------------------------------------------------------------------------------
# Command Dispatcher
# ------------------------------------------------------------------------------
action="${1:-status}"
shift 2>/dev/null || true

case "$action" in
    install)
        install
        ;;
    uninstall)
        uninstall
        ;;
    status)
        show_status
        ;;
    add)
        add_app "$@"
        ;;
    remove|rm)
        remove_app "$@"
        ;;
    list|ls)
        list_apps
        ;;
    help|--help|-h)
        echo "Eternal Summer ☀️ - GUI Priority & Anti-Freeze Manager"
        echo ""
        echo "Usage:"
        echo "  $0 status                     Show live system responsiveness & priorities"
        echo "  $0 list                       List all prioritized applications"
        echo "  $0 add <app> [nice] [oom]     Add an application to priority list"
        echo "  $0 remove <app>               Remove an application from priority list"
        echo "  sudo $0 install               Install full system-wide optimization stack"
        echo "  sudo $0 uninstall             Completely revert system back to defaults"
        echo ""
        echo "Examples:"
        echo "  $0 add konsole                Boost Konsole to Nice -10, OOM -500"
        echo "  $0 add steam -12 -600         Boost Steam to Nice -12, OOM -600"
        echo "  $0 remove konsole             Remove Konsole from priority list"
        ;;
    *)
        echo "Unknown command: '$action'"
        echo "Run '$0 help' for available commands."
        exit 1
        ;;
esac
