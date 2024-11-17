#!/bin/bash -x

function is_cent_os {
    [ -f /etc/redhat-release ]
}

function cleanup_bash_history {
    shred -u ~/.*history
    history -cw
}

function packages_cleanup {
    if is_cent_os ; then
        yum clean all -y
    else 
        apt autoremove -y
        apt-get clean -y
    fi
}

function remove_downloaded_files {
    rm -f provision_shared.sh
    rm -f cleanup.sh
}

cleanup_bash_history
packages_cleanup
remove_downloaded_files