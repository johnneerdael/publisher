#!/bin/bash

set -e

# Progress file to track steps
PROGRESS_FILE="/var/log/upgrade_progress.log"
SERVICE_FILE="/etc/systemd/system/ubuntu-upgrade.service"

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
    DEBIAN_FRONTEND=noninteractive apt-get install -y wget bind9-tools || {
        echo "Failed to install minimal packages"
        exit 1
    }
}

perform_upgrade() {
    echo "Performing system upgrade..."
    apt-get update
    apt-get dist-upgrade -y
    local version=$(lsb_release -rs)
    if [[ "$version" == "20.04" ]]; then
        sed -i 's/Prompt=lts/Prompt=normal/' /etc/update-manager/release-upgrades
        do-release-upgrade -f DistUpgradeViewNonInteractive
        check_reboot
    elif [[ "$version" == "22.04" ]]; then
        do-release-upgrade -f DistUpgradeViewNonInteractive
        check_reboot
    fi
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

main() {
    create_systemd_service
    fix_system_configuration
    install_minimal_packages
    perform_upgrade
    fix_dns_configuration
    post_upgrade_tasks
    clean_up
}

main