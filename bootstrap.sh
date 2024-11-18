#!/bin/bash

set -e

# Progress file to track steps
PROGRESS_FILE="/var/log/upgrade_progress.log"
SERVICE_FILE="/etc/systemd/system/ubuntu-upgrade.service"

# Add these status tracking functions at the top
STAGE_FILE="/var/log/upgrade_stage"

function log_progress() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$PROGRESS_FILE"
}

function set_stage() {
    local stage="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$stage" > "$STAGE_FILE"
    log_progress "Setting stage to: $stage"
}

function get_stage() {
    if [ -f "$STAGE_FILE" ]; then
        cat "$STAGE_FILE"
    else
        echo "init"
    fi
}

function handle_pending_reboot() {
    if [ -f /var/run/reboot-required ] || needs_reboot; then
        log_progress "System requires a reboot before continuing..."
        set_stage "pending_reboot"
        
        # Ensure our script runs again after reboot
        create_systemd_service
        
        # Force sync to ensure all writes are complete
        sync
        
        # Set a flag file to indicate we initiated the reboot
        touch /var/run/upgrade-reboot-initiated
        
        log_progress "Scheduling reboot in 30 seconds..."
        shutdown -r +1 "System will reboot in 1 minute to continue upgrade process..."
        
        # Wait for the reboot to happen
        sleep 70
        
        # If we get here, something went wrong with the reboot
        log_progress "ERROR: System did not reboot as expected"
        exit 1
    fi
}

function needs_reboot() {
    # Check various conditions that might require a reboot
    if dpkg -l | grep -q "^rc.*linux-image-"; then
        return 0
    fi
    if [ -f /var/lib/ubuntu-release-upgrader/release-upgrade-available ]; then
        return 0
    fi
    # Check if any services need restart
    if [ -x "$(command -v needrestart)" ]; then
        if needrestart -b | grep -q "NEEDRESTART-KSTA: 1"; then
            return 0
        fi
    fi
    return 1
}

# Check Ubuntu version and determine upgrade path
check_ubuntu_version() {
    local version=$(lsb_release -rs)
    echo "Current Ubuntu version: $version"
    
    case $version in
        "20.04")
            echo "Ubuntu 20.04 detected - will upgrade to 22.04"
            return 0
            ;;
        "22.04")
            echo "Ubuntu 22.04 detected - will upgrade to 24.04"
            return 0
            ;;
        "24.04")
            echo "Ubuntu 24.04 detected - no upgrade needed"
            return 1
            ;;
        *)
            echo "Unsupported Ubuntu version: $version"
            exit 1
            ;;
    esac
}

resume_from() {
    if [ -f "$PROGRESS_FILE" ]; then
        cat "$PROGRESS_FILE"
    else
        echo "start"
    fi
}

create_systemd_service() {
    echo "Creating systemd service for automatic resume..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Resume Ubuntu Upgrade After Reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'chmod +x /home/ubuntu/bootstrap.sh && /home/ubuntu/bootstrap.sh'
StandardOutput=journal
StandardError=journal
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ubuntu-upgrade
    systemctl start ubuntu-upgrade
}

cleanup_systemd_service() {
    echo "Cleaning up systemd service..."
    systemctl disable ubuntu-upgrade || true
    systemctl stop ubuntu-upgrade || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
}

check_reboot() {
    if [ -f /var/run/reboot-required ]; then
        echo "Reboot required. Rebooting..."
        reboot
        exit 0
    fi
}

# Fix DNS Configuration
fix_dns_configuration() {
    echo "Fixing DNS configuration..."

    # Ensure /etc/resolv.conf is not immutable
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # Check existing DNS servers from /etc/resolv.conf or set to Quad9 if none are configured
    if [ -f /etc/resolv.conf ] && grep -q "nameserver" /etc/resolv.conf; then
        echo "Using existing DNS servers from /etc/resolv.conf"
    else
        echo "No DNS servers found in /etc/resolv.conf. Configuring Quad9 DNS..."
        echo "nameserver 9.9.9.10" > /etc/resolv.conf
        echo "nameserver 149.112.112.10" >> /etc/resolv.conf
    fi

    # Test DNS resolution
    if ! host google.com >/dev/null 2>&1; then
        echo "DNS resolution failed. Configuring fallback to Quad9 DNS..."
        echo "nameserver 9.9.9.10" > /etc/resolv.conf
        echo "nameserver 149.112.112.10" >> /etc/resolv.conf
    fi

    # Prevent overwrites to /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true

    # Ensure no processes are listening on port 53
    echo "Ensuring no services are listening on port 53..."
    for service in systemd-resolved bind9 dnscrypt-proxy; do
        systemctl stop $service || true
        systemctl disable $service || true
        systemctl mask $service || true
    done

    # Verify port 53 is not in use
    if ss -tuln | grep -q ":53"; then
        echo "ERROR: A service is still listening on port 53. Manual intervention required."
        exit 1
    fi

    echo "DNS configuration complete with no services listening on port 53."
}

fix_system_configuration() {
    echo "Fixing system configuration..."
    mkdir -p /var/log/journal
    systemctl restart systemd-journald || true
}

install_minimal_packages() {
    echo "Installing minimal packages..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wget dnsutils net-tools || {
        echo "Failed to install minimal packages"
        exit 1
    }
}

# Modify the perform_upgrade function
function perform_upgrade() {
    local current_stage=$(get_stage)
    log_progress "Performing upgrade from stage: $current_stage"
    
    case $current_stage in
        "init"|"")
            log_progress "Starting initial upgrade..."
            DEBIAN_FRONTEND=noninteractive apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
            handle_pending_reboot
            set_stage "base_upgrade_complete"
            ;;
            
        "base_upgrade_complete")
            log_progress "Proceeding with release upgrade..."
            local version=$(lsb_release -rs)
            case $version in
                "20.04")
                    log_progress "Upgrading from 20.04 to 22.04..."
                    sed -i 's/Prompt=lts/Prompt=normal/' /etc/update-manager/release-upgrades
                    DEBIAN_FRONTEND=noninteractive do-release-upgrade -f DistUpgradeViewNonInteractive
                    handle_pending_reboot
                    set_stage "release_upgrade_complete"
                    ;;
                "22.04")
                    if do-release-upgrade -c; then
                        log_progress "Upgrading from 22.04 to 24.04..."
                        DEBIAN_FRONTEND=noninteractive do-release-upgrade -f DistUpgradeViewNonInteractive
                        handle_pending_reboot
                        set_stage "release_upgrade_complete"
                    else
                        log_progress "Upgrade to 24.04 not yet available"
                        set_stage "complete"
                    fi
                    ;;
            esac
            ;;
            
        "release_upgrade_complete")
            log_progress "Performing final system updates..."
            DEBIAN_FRONTEND=noninteractive apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
            handle_pending_reboot
            set_stage "complete"
            ;;
            
        "complete")
            log_progress "Upgrade process completed successfully"
            ;;
    esac
}

post_upgrade_tasks() {
    echo "Executing post-upgrade tasks..."
    apt-get install -y iptables iptables-persistent
    S3_PATH="https://s3-us-west-2.amazonaws.com/publisher.netskope.com/latest/generic"
    wget "$S3_PATH/npa-publisher.ubuntu.service" -O npa-publisher.service
    wget "https://raw.githubusercontent.com/johnneerdael/publisher/refs/heads/main/provision_shared.sh" -O provision_shared.sh
    wget "$S3_PATH/cleanup.sh" -O cleanup.sh
    chmod +x provision_shared.sh cleanup.sh
    ./provision_shared.sh "hardening_ssh_yes" || true
    ./cleanup.sh || true
}

clean_up() {
    echo "Cleaning up..."
    apt-get autoremove -y
    apt-get clean
    cleanup_systemd_service
}

# Add this function after check_ubuntu_version()
check_netskope_provisioning() {
    # Check for common Netskope publisher indicators
    if [ -f "$HOME/resources/.password_expiry_disabled" ] && \
       [ -d "$HOME/resources" ] && \
       [ -d "$HOME/logs" ] && \
       docker images | grep -q "new_edge_access"; then
        echo "Netskope provisioning detected"
        return 0
    fi
    echo "No existing Netskope provisioning detected"
    return 1
}

# Add this function before the main() function
function configure_firewall_npa() {
    # Ubuntu section for nftables
    apt-get install -y nftables ufw iptables-nft
    
    # Ensure nftables is enabled and started
    systemctl enable nftables
    systemctl start nftables
    
    # Create the base nftables configuration
    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain POSTROUTING {
        type nat hook postrouting priority 100;
        
        # SNAT rules for CGNAT
        ip saddr 100.64.0.0/10 counter masquerade
        ip saddr 191.1.0.0/16 counter masquerade
    }
}

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Allow established/related connections
        ct state established,related accept
        
        # Allow loopback
        iifname "lo" accept
        
        # Block invalid loopback traffic
        ip saddr 127.0.0.0/8 iifname != "lo" drop
        ip6 saddr ::1 iifname != "lo" drop
        
        # Allow SSH
        tcp dport 22 accept
        
        # NPA-specific rules
        ip daddr 191.1.1.1 tcp dport 784 accept
        ip daddr 191.1.1.1 udp dport 785 accept
        
        # TUN interface rules
        iifname "tun0" tcp dport 53 accept
        iifname "tun0" udp dport 53 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

    # Apply the nftables configuration
    nft -f /etc/nftables.conf
    
    # Ensure nftables rules persist across reboots
    systemctl enable nftables
    
    # Configure UFW to use nftables backend
    update-alternatives --set iptables /usr/sbin/iptables-nft
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
    update-alternatives --set arptables /usr/sbin/arptables-nft
    update-alternatives --set ebtables /usr/sbin/ebtables-nft
    
    # Configure basic UFW rules
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow to 191.1.1.1/32 proto tcp port 784
    ufw allow to 191.1.1.1/32 proto udp port 785
    
    echo y | ufw enable
    ufw reload

    echo "Firewall configuration complete!"
}

# Modify the main function
function main() {
    # Ensure we're running as root
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root"
        exit 1
    fi

    # Initialize logging
    log_progress "Starting upgrade process"
    
    local current_stage=$(get_stage)
    log_progress "Current stage: $current_stage"
    
    # Check if we're resuming after a reboot
    if [ -f /var/run/upgrade-reboot-initiated ]; then
        log_progress "Resuming after reboot"
        rm -f /var/run/upgrade-reboot-initiated
        if [ "$current_stage" = "pending_reboot" ]; then
            log_progress "Continuing from previous stage"
            set_stage "base_upgrade_complete"
            current_stage="base_upgrade_complete"
        fi
    fi

    if ! check_ubuntu_version; then
        echo "No OS upgrade needed."
        if ! update-alternatives --get-selections | grep -q "iptables-nft"; then
            echo "Migrating to iptables-nft..."
            apt-get install -y iptables-nft
            update-alternatives --set iptables /usr/sbin/iptables-nft
            update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
            update-alternatives --set arptables /usr/sbin/arptables-nft
            update-alternatives --set ebtables /usr/sbin/ebtables-nft
            configure_firewall_npa
        fi
        
        if check_netskope_provisioning; then
            echo "Skipping full provisioning, only updating necessary components..."
            fix_dns_configuration
            clean_up
            exit 0
        fi
        
        post_upgrade_tasks
        clean_up
        exit 0
    fi

    fix_system_configuration
    install_minimal_packages
    perform_upgrade
    
    if [ "$(get_stage)" = "complete" ]; then
        fix_dns_configuration
        post_upgrade_tasks
        clean_up
        rm -f "$STAGE_FILE"
    fi
}

# Call main at the end
main
