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
    [ -f /etc/redhat-release ]
}

function update_packages {
    if is_cent_os ; then
        yum update -y
    else
        apt-get -y update
        apt-get -y upgrade
    fi
}

function install_docker_ce {
    if is_cent_os ; then
        # Install Docker CE on CentOS
        yum install -y yum-utils device-mapper-persistent-data lvm2 
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce
        systemctl enable docker
        usermod -a -G docker $USER
        service docker start
    else
        # Install prerequisites for APT repository management
        apt-get install -y apt-transport-https ca-certificates curl software-properties-common

        # Add Docker's official GPG key
        if [ "$(lsb_release -rs)" = "24.04" ]; then
            # Proper method for Ubuntu 24.04+
            echo "Using modern method for Ubuntu 24.04+"
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
        else
            # Legacy method for older versions
            echo "Using legacy method for pre-24.04 Ubuntu"
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
    fi
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
    if is_cent_os ; then
        yum remove linux-firmware -y
    else
        kernel_version=$(uname -r)
        distro=$(echo "$kernel_version" | awk -F '-' '{print $NF}')
        if [ "$distro" != "generic" ] ; then
                apt-get remove linux-firmware -y
        fi
    fi
}

function hardening_install_cracklib {
    if is_cent_os ; then
        yum install cracklib -y
    else
        apt-get install cracklib-runtime -y
    fi
}

function install_network_utils {
    if is_cent_os ; then
        yum install -y net-tools bind-utils
    else
        apt-get install -y net-tools bind9-utils
    fi
}

function configure_firewall_npa {
    if is_cent_os; then
        yum install -y firewalld
        systemctl enable firewalld
        systemctl start firewalld
        
        # Configure firewalld for NPA-specific rules
        firewall-cmd --reload
        firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" destination address="191.1.1.1/32" port protocol="tcp" port="784" accept'
        firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" destination address="191.1.1.1/32" port protocol="udp" port="785" accept'
        firewall-cmd --permanent --new-zone=publisher_tunnel 
        firewall-cmd --permanent --zone=publisher_tunnel --add-interface=tun0
        firewall-cmd --permanent --zone=publisher_tunnel --add-rich-rule='rule family="ipv4" port protocol="tcp" port="53" accept'
        firewall-cmd --permanent --zone=publisher_tunnel --add-rich-rule='rule family="ipv4" port protocol="udp" port="53" accept'
        firewall-cmd --permanent --zone=publisher_tunnel --add-rich-rule='rule family="ipv4" destination address="191.1.1.1/32" port protocol="tcp" port="784" accept'
        firewall-cmd --permanent --zone=publisher_tunnel --add-rich-rule='rule family="ipv4" destination address="191.1.1.1/32" port protocol="udp" port="785" accept'
        firewall-cmd --reload
        
        systemctl restart firewalld
    else
        # Ubuntu use ufw as firewall by default
        apt-get install -y ufw iptables iptables-persistent
        update-alternatives --remove iptables /usr/sbin/iptables-legacy

        # Configure ufw rules for NPA-specific functionality
        ufw allow to 191.1.1.1/32 proto tcp port 784
        ufw allow to 191.1.1.1/32 proto udp port 785
        ufw allow in on tun0 to any port 53 proto tcp
        ufw allow in on tun0 to any port 53 proto udp
        ufw allow 22/tcp
        ufw allow in on lo
        ufw deny in from 127.0.0.0/8
        ufw deny in from ::1
        ufw reload
        
        # Step 3: Apply SNAT for CGNAT source range
        echo "Applying SNAT for CGNAT source range..."
        iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 191.1.0.0/16 -j MASQUERADE

        # Step 4: Persist iptables rules
        if command -v netfilter-persistent &> /dev/null; then
           echo "Saving iptables rules for persistence..."
           sudo netfilter-persistent save
        else
           echo "Install iptables-persistent to save rules across reboots."
        echo y | ufw enable
    fi

    echo "Configuration complete!"

    echo "COMMIT" >> /etc/ufw/before.rules
    # Reload ufw to apply the changes
    ufw reload
    fi
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
    if is_cent_os ; then
        echo "We don't support the publisher auto upgrade for the CentOS"
    else
        echo "*/1 * * * * root cd $HOME/resources && ./npa_publisher_auto_upgrade.sh" > /etc/cron.d/npa_publisher_auto_upgrade
    fi
}

function disable_systemd_resolved {
    if is_cent_os ; then
        echo "No need to bypass the systemd-resolved on CentOS"
    else
        rm -f /etc/resolv.conf
        ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
}

function disable_release_motd {
    if is_cent_os ; then
        echo "No need to disable release motd on CentOS"
    else
        chmod 644 /etc/update-motd.d/91-release-upgrade
    fi
}

function leave_password_expiry_disabled_flag {
    if is_cent_os ; then
        echo "No need to leave the password expiry policy flag"
    else
        echo "disabled by default" > $HOME/resources/.password_expiry_disabled
    fi
}

function remove_unnecessary_utilities {
    if is_cent_os ; then
        echo "Skip to remove the unnecessary utilities"
        /home/ubuntu/npa_publisher_wizard
    else
        apt-get -y remove iputils-ping 
        apt-get -y remove wget
        apt-get -y remove curl
        apt-get -y remove netcat-openbsd
        snap remove lxd
        /home/ubuntu/npa_publisher_wizard
    fi
}

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
