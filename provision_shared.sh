#!/bin/bash -x

# This is a generic provisioning file
# It's currentl applied to all VM types (AMI's and OVA's)

if [ "$PUBLISHER_REPO" = "" ] ; then
    PUBLISHER_REPO=netskopeprivateaccess/publisher
fi

if [ "$PUBLISHER_IMAGE_TAG" = "" ] ; then
    PUBLISHER_IMAGE_TAG=latest
fi

if [ "$PUBLISHER_USER" = "" ] ; then
    USER=ubuntu
else
    USER=$PUBLISHER_USER
fi

if [ "$USER" = "" ] ; then
    echo "No username specificed. Exit!"
    exit 1
fi

if [ "$USER" = "root" ] ; then
    echo "Do not use the root to install the publisher. Exit!"
    exit 1
fi

HOME=`eval echo ~$USER`
if [ "$HOME" = "" ] ; then
    echo "Can not find the $USER home directory. Exit!"
    exit 1
fi

function is_cent_os {
    false  # Always return false since we no longer support CentOS
}

function update_packages {
    apt-get -y update
    apt-get -y upgrade
}

function install_docker_ce {
    # Install prerequisites for APT repository management
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common

    # Add Docker's official GPG key
    if [ "$(lsb_release -rs)" = "24.04" ]; then
        # Proper method for Ubuntu 24.04+
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    else
        # Legacy method for pre-24.04 Ubuntu
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    fi

    # Update and install Docker
    apt-get update
    apt-get install -y docker-ce

    # Ensure Docker is running
    while ! [[ "$(service docker status)" =~ "running" ]]; do sleep 1; done
    groupadd docker

    # Enable the user to run Docker commands
    sudo usermod -aG docker $USER
    sudo systemctl enable docker.service
    sudo systemctl enable containerd.service
}

function load_publisher_image {
    # Load docker image
    # sg command will execute thit with docker group permissions (this shell doesn't have it yet because we just loaded it)
    if [ -f $HOME/publisher_docker.tgz ]; then
        sg docker -c "gunzip -c $HOME/publisher_docker.tgz | docker load"
    else
        sg docker -c "docker pull $PUBLISHER_REPO:$PUBLISHER_IMAGE_TAG"
        sg docker -c "docker tag $PUBLISHER_REPO:$PUBLISHER_IMAGE_TAG new_edge_access:latest"
    fi
}

function prepare_for_publisher_start {
    # Let's create folders for publisher and set them to be owner user (vs root)
    # If we don't create them explicitly then docker engine will create it for us (under root user)
    sudo -i -u $USER mkdir $HOME/resources
    sudo -i -u $USER mkdir $HOME/logs
}

function configure_publisher_wizard_to_start_on_user_ssh {
    # There is a problem with the docker that sometimes it starts really slow and unavailable on first login
    # We depend on Docker being ready, so we want to wait for it explicitly
    if is_cent_os ; then
        echo "while [ \"\`systemctl is-active docker.service\`\" != \"active\" ]; do echo \"Waiting for Docker daemon to start. It can take a minute.\"; sleep 10; done" >> $HOME/.bash_profile
    else 
        echo "while ! [[ \"\`sudo service docker status\`\" =~ \"running\" ]]; do echo \"Waiting for Docker daemon to start. It can take a minute.\"; sleep 10; done" >> $HOME/.bash_profile
    fi
    
    # Allow to run wizard under sudo without entering a password
    echo "$USER      ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers > /dev/null
        
    # Configure publisher wizard to run on each SSH
    echo "sudo rm \$HOME/npa_publisher_wizard 2>/dev/null" >> $HOME/.bash_profile
    echo "docker run -v \$HOME:/home/host_home --rm --entrypoint cp new_edge_access:latest /home/npa_publisher_wizard /home/host_home/npa_publisher_wizard" >> $HOME/.bash_profile
    echo "sudo \$HOME/npa_publisher_wizard" >> $HOME/.bash_profile
}

function configure_publisher_wizard_to_start_on_boot {
    # Extract wizard for a launch on boot
    sg docker -c "docker run -v $HOME:/home/host_home --rm --entrypoint cp new_edge_access:latest /home/npa_publisher_wizard /home/host_home/npa_publisher_wizard"
    chmod +x $HOME/npa_publisher_wizard
    
    # Create a systemd service to start us on boot
    mv $HOME/npa-publisher.service /usr/lib/systemd/system
    chown root:root /usr/lib/systemd/system/npa-publisher.service
    systemctl enable npa-publisher
}

function launch_publisher {
    # ToDo: We should move this to publisher wizard
    # Configure for a publisher to start automatically
    HOST_OS_TYPE=ubuntu
    if is_cent_os ; then
        HOST_OS_TYPE=centos
    fi

    sg docker -c "docker run --restart always --network=host --privileged --memory-swappiness=0 -e HOST_OS_TYPE=$HOST_OS_TYPE -v $HOME/resources:/home/resources -v $HOME/logs:/home/logs -d new_edge_access:latest"
}

function hardening_ssh {
    # Update sshd_config
    if is_cent_os ; then
        # Below came from nessusd scan 
        # https://developer.ibm.com/answers/questions/187318/faq-how-do-i-disable-cipher-block-chaining-cbc-mod.html
        echo "PermitRootLogin no" >> /etc/ssh/sshd_config
        echo "Ciphers aes128-ctr,aes192-ctr,aes256-ctr" >> /etc/ssh/sshd_config
        echo "MACs hmac-sha1,umac-64@openssh.com,hmac-ripemd160" >> /etc/ssh/sshd_config
    else
        # 5.3.4 Ensure SSH access is limited | allow users
        # 5.3.6 Ensure SSH X11 forwarding is disabled
        # 5.3.7 Ensure SSH MaxAuthTries is set to 4 or less
        # 5.3.9 Ensure SSH HostbasedAuthentication is disabled
        # 5.3.10 Ensure SSH root login is disabled
        # 5.3.11 Ensure SSH PermitEmptyPasswords is disabled
        # 5.3.13 Ensure only strong Ciphers are used
        # 5.3.14 Ensure only strong MAC algorithms are used
        # 5.3.15 Ensure only strong Key Exchange algorithms are used
        # 5.3.20 Ensure SSH AllowTcpForwarding is disabled
        # 5.3.22 Ensure SSH MaxSessions is limited to 10
        # Set TCPKeepAlive to no
        # Set ClientAliveCountMax to 1
        echo "AllowUsers $USER" >> /etc/ssh/sshd_config
        sed -i 's/^#*MaxAuthTries [0-9]\+/MaxAuthTries 2/' /etc/ssh/sshd_config
        sed -i 's/^#*X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config
        echo "HostbasedAuthentication no" >> /etc/ssh/sshd_config
        echo "PermitRootLogin no" >> /etc/ssh/sshd_config
        echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config
        echo "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr" >> /etc/ssh/sshd_config
        echo "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256" >> /etc/ssh/sshd_config
        echo "KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256" >> /etc/ssh/sshd_config
        echo "AllowTcpForwarding no" >> /etc/ssh/sshd_config
        echo "MaxSessions 10" >> /etc/ssh/sshd_config
        sed -i 's/^#*TCPKeepAlive [yes|no]\+/TCPKeepAlive no/' /etc/ssh/sshd_config
        sed -i 's/^#*ClientAliveCountMax [0-9]\+/ClientAliveCountMax 1/' /etc/ssh/sshd_config
        echo "HostbasedAcceptedKeyTypes -ssh-rsa" >> /etc/ssh/sshd_config
        echo "HostKeyAlgorithms -ssh-rsa" >> /etc/ssh/sshd_config
        echo "PubkeyAcceptedKeyTypes -ssh-rsa" >> /etc/ssh/sshd_config
    fi
}

function hardening_disable_root_login_to_all_devices {
    #Disable ALL root login, ssh, console, tty1...
    echo > /etc/securetty
}

function hardening_remove_root_password {
    passwd -d root
    passwd --lock root
}

function hardening_disable_ctrl_alt_del {
    systemctl mask ctrl-alt-del.target
}

# Remove Linux firmware
function hardening_remove_linux_firmware {
    kernel_version=$(uname -r)
    distro=$(echo "$kernel_version" | awk -F '-' '{print $NF}')
    if [ "$distro" != "generic" ] ; then
        apt-get remove linux-firmware -y
    fi
}

function hardening_install_cracklib {
    apt-get install cracklib-runtime -y
}

function install_network_utils {
    apt-get install -y net-tools bind9-utils
}

function configure_firewall_npa {
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

function configure_docker_daemon {
    echo -e "{\n\"bridge\": \"eth0\",\n\"iptables\": true\n}" > /etc/docker/daemon.json
}

function disable_coredumps {
    sh -c "echo 'kernel.core_pattern=|/bin/false' > /etc/sysctl.d/50-coredump.conf"
    sysctl -p /etc/sysctl.d/50-coredump.conf
}

function create_host_os_info_cronjob {  
    echo "*/5 * * * * root cd $HOME/resources && ./npa_publisher_collect_host_os_info.sh" > /etc/cron.d/npa_publisher_collect_host_os_info
}

function create_auto_upgrade_cronjob {
    echo "*/1 * * * * root cd $HOME/resources && ./npa_publisher_auto_upgrade.sh" > /etc/cron.d/npa_publisher_auto_upgrade
}

function disable_systemd_resolved {
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
}

function disable_release_motd {
    chmod 644 /etc/update-motd.d/91-release-upgrade
}

function leave_password_expiry_disabled_flag {
    echo "disabled by default" > $HOME/resources/.password_expiry_disabled
}

function remove_unnecessary_utilities {
    apt-get -y remove iputils-ping 
    apt-get -y remove wget
    apt-get -y remove curl
    apt-get -y remove netcat-openbsd
    snap remove lxd
    /home/ubuntu/npa_publisher_wizard
}

function check_existing_installation() {
    if [ -f "$HOME/resources/.password_expiry_disabled" ] && \
       [ -d "$HOME/resources" ] && \
       [ -d "$HOME/logs" ] && \
       docker images | grep -q "new_edge_access"; then
        echo "Existing Netskope installation detected"
        
        # Check if we need to migrate to nftables
        if ! update-alternatives --get-selections | grep -q "iptables-nft"; then
            echo "Migrating to iptables-nft..."
            apt-get install -y iptables-nft
            update-alternatives --set iptables /usr/sbin/iptables-nft
            update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
            update-alternatives --set arptables /usr/sbin/arptables-nft
            update-alternatives --set ebtables /usr/sbin/ebtables-nft
            
            # Reconfigure firewall with nftables
            configure_firewall_npa
        else
            echo "iptables-nft already configured"
        fi
        
        return 0
    fi
    return 1
}

if check_existing_installation; then
    echo "Skipping full provisioning as Netskope is already installed"
    # Only perform necessary updates
    update_packages
    configure_firewall_npa  # This will handle nftables migration if needed
    exit 0
fi

# Rest of the original execution flow for new installations
update_packages
install_network_utils
configure_firewall_npa
install_docker_ce
configure_docker_daemon
create_host_os_info_cronjob
create_auto_upgrade_cronjob
disable_systemd_resolved
load_publisher_image
prepare_for_publisher_start
configure_publisher_wizard_to_start_on_user_ssh

# We need this currently only on AWS
configure_publisher_wizard_to_start_on_boot
launch_publisher

# hardening ssh if needed
if [ "$#" -ge 1 ] && [ "$1" = "hardening_ssh_yes" ]; then
    hardening_ssh
fi

hardening_install_cracklib
hardening_disable_root_login_to_all_devices
hardening_remove_root_password
hardening_disable_ctrl_alt_del
hardening_remove_linux_firmware
disable_coredumps
disable_release_motd
leave_password_expiry_disabled_flag
remove_unnecessary_utilities
