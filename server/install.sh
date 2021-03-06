#!/bin/bash -eu

die() { echo "$*" >&2; exit 1; }

id factory >/dev/null || die "Cannot install on this system"

usage() 
{
    die "\
Usage:

    $0 [options]

Install or uninstall factory server. Options are:

   -b  - backup database to /var/factory.backup.*.gz
   -u  - uninstall server
   -p  - purge packages, if already uninstalled
   -i  - install server, if not already installed

Actions will be performed in the order listed here. 

To do a fresh install, use './install -i'.

To update an existing install (after git pull), use 'install.sh -ui'.

To completely uninstall use 'install.sh -up' but note the database will remain
intact." 
}

((!UID)) || die "Must be root"

# mandatory packages
PACKAGES=(apache2 curl dnsmasq iptables-persistent postgresql python-psycogreen resolvconf sudo)

# extra packages
PACKAGES+=(arping links mlocate net-tools psmisc smartmontools sysstat tcpdump tmux vim)

install=
uninstall=
purge=
backup=

(($#)) || usage
while getopts "bipu" o; do case $o in
    b) backup=1 ;;
    i) install=1 ;;
    u) uninstall=1 ;;
    p) purge=1 ;;
    *) usage ;;
esac; done

# read the config file
here=${0%/*}
source $here/install.cfg
[[ -n ${dut_interface:-} ]] || die "install.cfg does not define 'dut_interface'"
[[ -n ${factory_interface:-} ]] || die "install.cfg does not define 'factory_interface'"
[[ -n ${dut_ip:-} ]] || die "install.cfg does not define 'dut_ip'"
[[ -n ${factory_id:-} ]] || die "install.cfg does not define 'factory_id'"
[[ -n ${organization:-} ]] || die "install.cfg does not define 'organization'"

# execute given command as postgres user
postgres() { 
    id postgres >/dev/null || die "postgresql is not installed"
    su -lc "$*" postgres
}

if ((backup)); then
    tmp=$(mktemp /var/factory.backup.XXXXXXXX.gz) || die "mktemp failed"
    echo "Backing up database to $tmp..."
    postgres pg_dump factory | gzip -9 > $tmp
fi

if ((uninstall)); then

    ifdown $dut_interface || true

    echo "Removing overlay"
    for f in $(find $here/overlay -type f,l -printf "%P\n"); do
        rm -f /$f
        # restore originals from backup
        ! [ -e /$f~ ] || cp -vP /$f~ /$f
    done

    echo "Disabling iptables"
    iptables -P INPUT ACCEPT
    iptables -F
    iptables -F -t nat
    systemctl disable netfilter-persistent

    rm -rf /etc/factory

    # Other obsolete stuff
    rm -f /home/factory/downloads

    # look for uninstall issues
    for f in $(find $here/overlay -type f,l -printf "%P\n"); do
        if [ -e /$f ] && diff /$f $here/overlay/$f &>/dev/null; then
        {
            echo "WARNING: /$f is the same as $here/overlay/$f"
            echo "You may need to restore it manually with:"
            echo "    dpkg -S /$file (to determine the source package name)"
            echo "    apt install --reinstall -o Dpkg::Options::=--force-confask,confnew,confmiss <the-source-package>"
            echo "If that doesn't work, look for a generation script in /var/lib/dpkg/info/*.postint"
        } >&2
        fi
        # delete residual backup
        rm -f /$f~
    done

    echo "###################"
    echo "Uninstall complete!"
fi

if ((purge)); then
    ! [ -d /etc/factory ] || die "Currently installed, try '$0 -up' to uninstall and purge pacakges."
    echo "Purging packages"    

    export DEBIAN_FRONTEND=noninteractive
    apt -qy remove --purge --autoremove ${PACKAGES[@]}
    apt -qy autoremove --purge

    echo "###############"
    echo "Purge complete!"
fi

if ((install)); then
    ! [ -d /etc/factory ] || die "Already installed, try '$0 -ui' to update."

    [[ -n ${factory_interface:-} ]] || die "install.cfg does not define 'factory_interface'"
    [[ -n ${dut_ip:-} ]] || die "install.cfg does not define 'dut_ip'"
    [[ -n ${factory_id:-} ]] || die "install.cfg does not define 'factory_id'"
    [[ -n ${organization:-} ]] || die "install.cfg does not define 'organization'"

    # Verify interfaces
    [ -e /sys/class/net/$factory_interface ] || die "Invalid network interface $factory_interface"
    (($(cat /sys/class/net/$factory_interface/carrier 2>/dev/null))) || die "$factory_interface must be connected!"

    [ -e /sys/class/net/$dut_interface ] || die "Invalid network interface $dut_interface"
    ! (($(cat /sys/class/net/$dut_interface/carrier 2>/dev/null))) || die "$dut_interface must not be connected!"

    echo "Installing packages"
    export DEBIAN_FRONTEND=noninteractive
    apt -qy update
    apt -qy upgrade
    apt -qy install -qy ${PACKAGES[@]}

    echo "Installing overlay"
    for f in $(find $here/overlay -type f,l -printf "%P\n"); do

        # create directory if needed
        [ -d /${f%/*} ] || mkdir -v -p /${f%/*}

        # if file already exists and backup does not, make a backup
        ! [ -e /$f ] || [ -e /$f~ ] || cp -vP /$f /$f~

        cp -vP $here/overlay/$f /$f

        # rewriting special tags
        [ -h /$f ] ||
        sed -i "s/FACTORY_INTERFACE/$factory_interface/g;
                s/DUT_INTERFACE/$dut_interface/g;
                s/DUT_IP/$dut_ip/g;
                s/DUT_NET/${dut_ip%.*}.*/g;
                s/FACTORY_ID/$factory_id/g;
                s/ORGANIZATION/$organization/g;" /$f

    done

    # allow uninstall after this point
    git rev-parse HEAD --abbrev-ref HEAD > /etc/factory/installed

    echo "Fix permissions"
    chown -R factory: ~factory/
    chmod -R go= ~factory/.ssh
    chown root:root /var/www/html/downloads
    chmod 777 /var/www/html/downloads

    echo "Configuring postgresql"
    postgres psql -f /etc/factory/schema.txt 2>&1 | egrep -v 'ERROR:.*(already exists|does not exist)'

    echo "Configuring Apache"
    a2enmod cgi
    a2enmod ssl
    a2ensite default-ssl

    # force UCT
    ln -sf /usr/share/zoneinfo/UCT /etc/localtime

    echo "Configure iptables"
    iptables -P INPUT ACCEPT
    iptables -F # flush everything
    iptables -F -t nat
    iptables -X # delete user chains
    iptables -Z # zero counters

    # trust lo
    iptables -A INPUT -i lo -j ACCEPT

    # allow expected
    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

    # ssh from anywhere
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT

    # http from dut interface
    iptables -A INPUT -i $dut_interface -p tcp --dport 80 -j ACCEPT

    # dhcp from dut interface
    iptables -A INPUT -i $dut_interface -p udp --dport 67 -j ACCEPT

    # dns from dut interface
    iptables -A INPUT -i $dut_interface -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -i $dut_interface -p tcp --dport 53 -j ACCEPT

    # https from non-routable networks
    iptables -A INPUT -p tcp -s 10.0.0.0/8     --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp -s 172.16.0.0/12  --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp -s 192.168.0.0/16 --dport 443 -j ACCEPT

    # NAT forward DUTs
    iptables -t nat -A POSTROUTING -o $factory_interface -j MASQUERADE

    # drop all other inputs
    iptables -P INPUT DROP

    # save for boot script
    iptables-save > /etc/iptables/rules.v4

    # disable ipv6
    ip6tables -F # flush everything
    ip6tables -P INPUT DROP
    ip6tables-save > /etc/iptables/rules.v6

    systemctl enable netfilter-persistent

    echo "Configuring dnsmasq"
    ifup $dut_interface
    /etc/factory/update.dnsmasq

    echo "#################"
    echo "Install complete!"
fi
