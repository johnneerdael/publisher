#!/bin/bash

set -e

# Progress file to track steps
PROGRESS_FILE="/var/log/upgrade_progress.log"
SERVICE_FILE="/etc/systemd/system/ubuntu-upgrade.service"

# Add these status tracking functions at the top
STAGE_FILE="/var/log/upgrade_stage"

function set_stage() {
    echo "$1" > "$STAGE_FILE"
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
        echo "System requires a reboot before continuing..."
        set_stage "pending_reboot"
        # Ensure our script runs again after reboot
        create_systemd_service
        reboot
        exit 0
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

log_step() {
    echo "$1" > "$PROGRESS_FILE"
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
After=network.target

[Service]
ExecStart=/home/ubuntu/bootstrap.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ubuntu-upgrade
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
    
    case $current_stage in
        "init"|"")
            echo "Starting initial upgrade..."
            apt-get update
            apt-get dist-upgrade -y
            handle_pending_reboot
            set_stage "base_upgrade_complete"
            ;;
            
        "base_upgrade_complete")
            echo "Proceeding with release upgrade..."
            local version=$(lsb_release -rs)
            case $version in
                "20.04")
                    echo "Upgrading from 20.04 to 22.04..."
                    sed -i 's/Prompt=lts/Prompt=normal/' /etc/update-manager/release-upgrades
                    do-release-upgrade -f DistUpgradeViewNonInteractive
                    handle_pending_reboot
                    set_stage "release_upgrade_complete"
                    ;;
                "22.04")
                    if do-release-upgrade -c; then
                        echo "Upgrading from 22.04 to 24.04..."
                        do-release-upgrade -f DistUpgradeViewNonInteractive
                        handle_pending_reboot
                        set_stage "release_upgrade_complete"
                    else
                        echo "Upgrade to 24.04 not yet available"
                        set_stage "complete"
                    fi
                    ;;
            esac
            ;;
            
        "release_upgrade_complete")
            echo "Performing final system updates..."
            apt-get update
            apt-get dist-upgrade -y
            handle_pending_reboot
            set_stage "complete"
            ;;
            
        "complete")
            echo "Upgrade process completed successfully"
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

# Modify the main function
function main() {
    local current_stage=$(get_stage)
    
    if [ "$current_stage" = "pending_reboot" ]; then
        echo "Resuming after reboot..."
        set_stage "base_upgrade_complete"
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

main
