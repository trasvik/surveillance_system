#!/bin/bash

# ======================================================================
# RASPBERRY PI SURVEILLANCE SETUP SCRIPT - PRODUCTION READY
# Version: 2.1
# Last Updated: 2023-11-15
# ======================================================================

# Exit immediately if a command fails, prevent unset variable usage
set -eo pipefail
shopt -s inherit_errexit

# ======================== CONFIGURATION ===============================
MOTION_EYE_PORT=8765
STORAGE_DIR="/mnt/motion"
TEMP_DIR="/tmp/pi_surveillance_setup"
MIN_DISK_SPACE=1048576  # 1GB in KB
LOG_FILE="/var/log/pi_surveillance_setup.log"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ======================== INITIALIZATION =============================
initialize() {
    # Setup logging
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "\n${BLUE}=== Surveillance Setup Started $(date) ===${NC}"
    
    # Create temp directory
    mkdir -p "$TEMP_DIR"
    trap 'cleanup' EXIT
    
    check_root
    check_resources
}

cleanup() {
    echo -e "${BLUE}Cleaning up temporary files...${NC}"
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}Cleanup complete.${NC}"
}

# ======================== SYSTEM CHECKS ==============================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root (sudo).${NC}" >&2
        exit 1
    fi
}

check_resources() {
    echo -e "${YELLOW}[1/6] Checking system resources...${NC}"
    
    # Check disk space
    local free_space=$(df / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt "$MIN_DISK_SPACE" ]; then
        echo -e "${RED}Error: Insufficient disk space (only ${free_space}KB available).${NC}"
        echo -e "${YELLOW}Please free up at least 1GB before continuing.${NC}"
        exit 1
    fi
    
    # Check RAM
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    if [ "$total_ram" -lt 900 ]; then
        echo -e "${YELLOW}Warning: Only ${total_ram}MB RAM detected. Performance may be affected.${NC}"
    fi
    
    # Check CPU cores
    local cores=$(nproc)
    echo -e "${BLUE}System Resources:${NC}"
    echo -e " - Disk: ${free_space}KB free"
    echo -e " - RAM: ${total_ram}MB"
    echo -e " - CPU Cores: ${cores}"
}

check_webcam() {
    echo -e "${YELLOW}Checking webcam...${NC}"
    
    if ! lsusb | grep -iq "Logitech"; then
        echo -e "${RED}Error: Logitech webcam not detected.${NC}"
        echo -e "${YELLOW}Please check:${NC}"
        echo -e "1. USB connection"
        echo -e "2. Try different USB port"
        echo -e "3. Verify webcam is UVC-compatible"
        exit 1
    fi
    
    # Install v4l-utils if missing
    if ! command -v v4l2-ctl >/dev/null; then
        apt-get install -y v4l-utils
    fi
    
    echo -e "${GREEN}✓ Webcam detected: $(lsusb | grep -i "Logitech")${NC}"
    echo -e "${BLUE}Supported formats:${NC}"
    v4l2-ctl --list-formats-ext | sed 's/^/  /'
    
    # Test webcam feed
    if ! timeout 5s v4l2-ctl --stream-mmap --stream-count=1 --stream-to=/dev/null; then
        echo -e "${RED}Error: Webcam feed test failed.${NC}"
        echo -e "${YELLOW}Troubleshooting steps:${NC}"
        echo -e "1. Try different USB port"
        echo -e "2. Check kernel modules: lsmod | grep uvcvideo"
        exit 1
    fi
}

# ====================== SOFTWARE INSTALLATION =========================
install_dependencies() {
    echo -e "${YELLOW}[2/6] Installing dependencies...${NC}"
    
    # Update package list with retry logic
    for i in {1..3}; do
        if apt-get update -q; then
            break
        elif [ "$i" -eq 3 ]; then
            echo -e "${RED}Failed to update package list after 3 attempts.${NC}"
            exit 1
        fi
        sleep 5
    done
    
    # Install core packages
    local core_packages=(
        v4l-utils
        python3-pip
        ffmpeg
        libjpeg-dev
        libssl-dev
        libcurl4-openssl-dev
        libz-dev
        gnupg
        curl
        wget
        ufw
        logrotate
    )
    
    apt-get install -y --no-install-recommends "${core_packages[@]}"
    
    # Install Motion
    if ! command -v motion >/dev/null; then
        echo -e "${BLUE}Installing motion...${NC}"
        apt-get install -y motion
    fi
    
    # Install MotionEye with pip
    if ! command -v motioneye >/dev/null; then
        echo -e "${BLUE}Installing MotionEye...${NC}"
        pip install --no-cache-dir motioneye
        
        # Configure MotionEye
        mkdir -p /etc/motioneye
        if [ ! -f /etc/motioneye/motioneye.conf ]; then
            cp /usr/local/share/motioneye/extra/motioneye.conf.sample /etc/motioneye/motioneye.conf
        fi
    fi
}

# ====================== STORAGE CONFIGURATION =========================
configure_storage() {
    echo -e "${YELLOW}[3/6] Configuring storage...${NC}"
    
    # Create storage directory
    mkdir -p "$STORAGE_DIR"
    chown motion:motion "$STORAGE_DIR"
    
    # Configure tmpfs if not already mounted
    if ! mountpoint -q "$STORAGE_DIR"; then
        echo -e "${BLUE}Setting up RAM disk for motion captures...${NC}"
        echo "tmpfs $STORAGE_DIR tmpfs defaults,noatime,nosuid,size=100M 0 0" >> /etc/fstab
        mount "$STORAGE_DIR"
    else
        echo -e "${YELLOW}Notice: $STORAGE_DIR is already mounted.${NC}"
    fi
    
    # Setup log rotation
    echo -e "${BLUE}Configuring log rotation...${NC}"
    cat > /etc/logrotate.d/pi_surveillance <<EOF
$LOG_FILE {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
}

# ====================== MOTIONEYE SERVICE SETUP =======================
setup_motioneye() {
    echo -e "${YELLOW}[4/6] Configuring MotionEye...${NC}"
    
    # Create systemd service if not exists
    if [ ! -f /etc/systemd/system/motioneye.service ]; then
        cat > /etc/systemd/system/motioneye.service <<EOF
[Unit]
Description=MotionEye
After=network.target
StartLimitIntervalSec=60

[Service]
ExecStart=/usr/local/bin/motioneye
Restart=always
RestartSec=5
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable motioneye
    fi
    
    # Check if port is available
    if ss -tuln | grep -q ":$MOTION_EYE_PORT"; then
        echo -e "${YELLOW}Port $MOTION_EYE_PORT is in use. Attempting to restart...${NC}"
        systemctl stop motioneye
    fi
    
    systemctl start motioneye
    
    # Verify service is running
    if ! systemctl is-active --quiet motioneye; then
        echo -e "${RED}Error: MotionEye failed to start.${NC}"
        echo -e "${YELLOW}Check logs with: journalctl -u motioneye${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ MotionEye running on port $MOTION_EYE_PORT${NC}"
}

# ====================== REMOTE ACCESS SETUP ===========================
setup_remote_access() {
    echo -e "${YELLOW}[5/6] Setting up remote access...${NC}"
    
    PS3="Select remote access method: "
    options=("Tailscale (P2P VPN)" "Cloudflare Tunnel (No VPN)" "Skip")
    select opt in "${options[@]}"; do
        case $opt in
            "Tailscale (P2P VPN)")
                install_tailscale
                break
                ;;
            "Cloudflare Tunnel (No VPN)")
                install_cloudflared
                break
                ;;
            "Skip")
                echo -e "${YELLOW}⚠ Remote access skipped.${NC}"
                break
                ;;
            *) 
                echo "Invalid option"
                ;;
        esac
    done
}

install_tailscale() {
    echo -e "${BLUE}Setting up Tailscale...${NC}"
    
    if ! command -v tailscale >/dev/null; then
        # Add Tailscale repository securely
        curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bullseye.tailscale-keyring.gpg | \
            gpg --dearmor > /usr/share/keyrings/tailscale.gpg
        echo "deb [signed-by=/usr/share/keyrings/tailscale.gpg] https://pkgs.tailscale.com/stable/raspbian bullseye main" \
            > /etc/apt/sources.list.d/tailscale.list
        
        apt-get update
        apt-get install -y tailscale
    fi
    
    # Start Tailscale with IPv4 first, fallback to IPv6
    if ! tailscale up --advertise-exit-node --accept-routes --reset; then
        echo -e "${YELLOW}IPv4 connection failed, trying IPv6...${NC}"
        tailscale up --advertise-exit-node --accept-routes --reset --operator=$USER --advertise-tags=tag:ipv6
    fi
    
    echo -e "${GREEN}✓ Tailscale configured. Access via:${NC}"
    echo -e " - ${YELLOW}https://$(tailscale ip -4):$MOTION_EYE_PORT${NC}"
}

install_cloudflared() {
    echo -e "${BLUE}Setting up Cloudflare Tunnel...${NC}"
    
    if ! command -v cloudflared >/dev/null; then
        # Get latest release URL
        CLOUDFLARED_URL=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | \
            grep "browser_download_url.*linux-arm" | cut -d '"' -f 4)
        
        # Download and install
        wget -q "$CLOUDFLARED_URL" -O "$TEMP_DIR/cloudflared"
        chmod +x "$TEMP_DIR/cloudflared"
        mv "$TEMP_DIR/cloudflared" /usr/local/bin/
    fi
    
    # Get Cloudflare token
    while [ -z "$CLOUDFLARE_TOKEN" ]; do
        read -rp "Enter Cloudflare Zero Trust token: " CLOUDFLARE_TOKEN
    done
    
    # Authenticate and create tunnel
    cloudflared tunnel login
    cloudflared tunnel create surv-tunnel
    cloudflared tunnel route dns surv-tunnel surv.yourdomain.com
    
    # Create systemd service
    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:$MOTION_EYE_PORT run surv-tunnel
Restart=always
RestartSec=5
User=root
Environment=CLOUDFLARED_ORIGIN_CERT=/root/.cloudflared/cert.pem

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl start cloudflared
    
    echo -e "${GREEN}✓ Cloudflare Tunnel configured. Access via:${NC}"
    echo -e " - ${YELLOW}https://surv.yourdomain.com${NC}"
}

# ====================== SECURITY HARDENING ===========================
harden_security() {
    echo -e "${YELLOW}[6/6] Securing system...${NC}"
    
    # Configure firewall
    echo -e "${BLUE}Setting up firewall...${NC}"
    ufw allow ssh
    ufw allow "$MOTION_EYE_PORT"
    ufw --force enable
    
    # Secure SSH
    echo -e "${BLUE}Hardening SSH...${NC}"
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/g' /etc/ssh/sshd_config
    systemctl restart sshd
    
    # Install and configure fail2ban
    if ! command -v fail2ban-client >/dev/null; then
        apt-get install -y fail2ban
        cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
        systemctl enable fail2ban
    fi
    systemctl start fail2ban
    
    # Set performance governor
    echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
    
    # Disable unnecessary services
    echo -e "${BLUE}Disabling unnecessary services...${NC}"
    systemctl disable --now bluetooth.service hciuart.service avahi-daemon.service
}

# ====================== MAIN EXECUTION ===============================
main() {
    initialize
    
    echo -e "${BLUE}=== Beginning Installation ===${NC}"
    check_webcam
    install_dependencies
    configure_storage
    setup_motioneye
    setup_remote_access
    harden_security
    
    # Final output
    echo -e "${GREEN}\n✔ Installation completed successfully!${NC}"
    echo -e "\n${BLUE}=== Access Information ===${NC}"
    echo -e "Local Access: ${YELLOW}http://$(hostname -I | awk '{print $1}'):$MOTION_EYE_PORT${NC}"
    
    if command -v tailscale >/dev/null; then
        echo -e "Tailscale Access: ${YELLOW}https://$(tailscale ip -4):$MOTION_EYE_PORT${NC}"
    fi
    
    echo -e "\n${BLUE}=== Next Steps ===${NC}"
    echo -e "1. Log in to MotionEye (admin/no password)"
    echo -e "2. Configure motion detection zones"
    echo -e "3. Set up alerts (Telegram/SMTP)"
    echo -e "\n${YELLOW}Detailed log available at: $LOG_FILE${NC}"
}

# Execute main function
main