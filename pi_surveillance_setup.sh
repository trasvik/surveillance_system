#!/bin/bash

# ======================================================================
# RASPBERRY PI SURVEILLANCE SETUP SCRIPT - MODERN VERSION
# Version: 3.0 - Compatible with Python 3.11+ and modern systems
# Last Updated: 2025-07-26
# ======================================================================

set -eo pipefail

# ======================== CONFIGURATION ===============================
MOTION_WEB_PORT=8080
MOTION_STREAM_PORT=8081
STORAGE_DIR="/var/lib/motion"
LOG_FILE="/var/log/pi_surveillance_setup.log"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ======================== FUNCTIONS ===================================

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "${RED}Error: This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

check_webcam() {
    log "${YELLOW}[1/5] Checking webcam...${NC}"
    
    if ! lsusb | grep -iq "logitech"; then
        log "${RED}Error: Logitech webcam not detected.${NC}"
        log "${YELLOW}Available USB devices:${NC}"
        lsusb
        exit 1
    fi
    
    # Install v4l-utils if missing
    if ! command -v v4l2-ctl >/dev/null; then
        apt-get install -y v4l-utils
    fi
    
    log "${GREEN}✓ Webcam detected: $(lsusb | grep -i "logitech")${NC}"
    
    # Show available video devices
    log "${BLUE}Available video devices:${NC}"
    v4l2-ctl --list-devices | head -20
}

install_dependencies() {
    log "${YELLOW}[2/5] Installing dependencies...${NC}"
    
    # Update package list
    apt-get update -q
    
    # Install core packages
    local packages=(
        v4l-utils
        motion
        ffmpeg
        curl
        wget
        ufw
        fail2ban
        logrotate
    )
    
    apt-get install -y "${packages[@]}"
    log "${GREEN}✓ Dependencies installed${NC}"
}

configure_motion() {
    log "${YELLOW}[3/5] Configuring Motion...${NC}"
    
    # Stop motion if running
    systemctl stop motion 2>/dev/null || true
    
    # Create storage directory
    mkdir -p "$STORAGE_DIR"
    chown motion:motion "$STORAGE_DIR"
    
    # Backup original config
    cp /etc/motion/motion.conf /etc/motion/motion.conf.backup 2>/dev/null || true
    
    # Create motion configuration
    cat > /etc/motion/motion.conf <<'EOF'
# Motion Configuration - Raspberry Pi Surveillance

# Daemon and process
daemon on
process_id_file /var/run/motion/motion.pid

# Video device settings
videodevice /dev/video0
width 640
height 480
framerate 15
auto_brightness off

# Image settings
output_pictures off
quality 85
picture_filename %Y%m%d%H%M%S-%q

# Movie settings
ffmpeg_output_movies on
ffmpeg_output_debug_movies off
ffmpeg_video_codec mp4
movie_filename %Y%m%d%H%M%S

# Storage
target_dir /var/lib/motion

# Motion detection
threshold 1500
minimum_motion_frames 1
event_gap 60
pre_capture 2
post_capture 2

# Stream settings
stream_port 8081
stream_localhost off
stream_auth_method 0
stream_maxrate 5

# Web control
webcontrol_port 8080
webcontrol_localhost off
webcontrol_auth_method 0

# Logging
log_level 6
log_type all
logfile /var/log/motion/motion.log

# Text overlay
text_left Camera 1
text_right %Y-%m-%d %T
EOF

    # Create log directory
    mkdir -p /var/log/motion
    chown motion:motion /var/log/motion
    
    # Enable and start motion
    systemctl enable motion
    systemctl start motion
    
    # Wait a moment and check status
    sleep 3
    if systemctl is-active --quiet motion; then
        log "${GREEN}✓ Motion service started successfully${NC}"
    else
        log "${RED}Error: Motion failed to start${NC}"
        log "${YELLOW}Check logs with: sudo journalctl -u motion${NC}"
        exit 1
    fi
}

setup_remote_access() {
    log "${YELLOW}[4/5] Setting up remote access...${NC}"
    
    echo "Choose remote access method:"
    echo "1) Tailscale (Recommended - P2P VPN)"
    echo "2) Skip remote access"
    read -p "Enter choice [1-2]: " choice
    
    case $choice in
        1)
            install_tailscale
            ;;
        2)
            log "${YELLOW}Remote access skipped${NC}"
            ;;
        *)
            log "${YELLOW}Invalid choice, skipping remote access${NC}"
            ;;
    esac
}

install_tailscale() {
    log "${BLUE}Installing Tailscale...${NC}"
    
    if ! command -v tailscale >/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    
    log "${BLUE}Starting Tailscale...${NC}"
    tailscale up
    
    local tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "Not connected")
    log "${GREEN}✓ Tailscale configured${NC}"
    log "${BLUE}Tailscale IP: ${tailscale_ip}${NC}"
}

configure_security() {
    log "${YELLOW}[5/5] Configuring security...${NC}"
    
    # Configure firewall
    ufw allow ssh
    ufw allow $MOTION_WEB_PORT
    ufw allow $MOTION_STREAM_PORT
    ufw --force enable
    
    # Configure fail2ban
    systemctl enable fail2ban
    systemctl start fail2ban
    
    log "${GREEN}✓ Security configured${NC}"
}

show_access_info() {
    local local_ip=$(hostname -I | awk '{print $1}')
    local tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "Not configured")
    
    log "${GREEN}\n✔ Installation completed successfully!${NC}"
    log "\n${BLUE}=== ACCESS INFORMATION ===${NC}"
    log "Local Access:"
    log "  Web Interface: ${YELLOW}http://${local_ip}:${MOTION_WEB_PORT}${NC}"
    log "  Live Stream:   ${YELLOW}http://${local_ip}:${MOTION_STREAM_PORT}${NC}"
    
    if [[ "$tailscale_ip" != "Not configured" ]]; then
        log "\nTailscale Access:"
        log "  Web Interface: ${YELLOW}http://${tailscale_ip}:${MOTION_WEB_PORT}${NC}"
        log "  Live Stream:   ${YELLOW}http://${tailscale_ip}:${MOTION_STREAM_PORT}${NC}"
    fi
    
    log "\n${BLUE}=== STORAGE ===${NC}"
    log "Videos saved to: ${STORAGE_DIR}"
    log "Motion logs: /var/log/motion/motion.log"
    
    log "\n${BLUE}=== USEFUL COMMANDS ===${NC}"
    log "Check Motion status: ${YELLOW}sudo systemctl status motion${NC}"
    log "View Motion logs:    ${YELLOW}sudo tail -f /var/log/motion/motion.log${NC}"
    log "Restart Motion:      ${YELLOW}sudo systemctl restart motion${NC}"
    
    log "\n${YELLOW}Setup log saved to: $LOG_FILE${NC}"
}

# ======================== MAIN EXECUTION ===============================
main() {
    # Initialize logging
    echo "=== Surveillance Setup Started $(date) ===" > "$LOG_FILE"
    
    log "${BLUE}=== Raspberry Pi Surveillance Setup (Modern) ===${NC}"
    
    check_root
    check_webcam
    install_dependencies
    configure_motion
    setup_remote_access
    configure_security
    show_access_info
}

# Execute main function
main "$@"
