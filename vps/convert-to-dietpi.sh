#!/bin/bash
# Convert a running Debian system (VPS, VM or bare metal) to DietPi.
# Run on the target machine as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/vps/convert-to-dietpi.sh)"
#
# Wraps the official dietpi-installer, which strips the system down to a
# DietPi base: packages, users and configs outside the base system are
# removed and the SSH host keys are reset. Treat it as a reinstall.
#
# Pass a factory.sh profile directory as first argument (or PROFILE_DIR),
# otherwise the base profile from the repo is used. ASSUME_YES=1 skips the
# confirmation.
set -euo pipefail

INSTALLER_URL=https://raw.githubusercontent.com/MichaIng/DietPi/master/.build/images/dietpi-installer
PROFILE_URL=https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/config
PROFILE_DIR=${PROFILE_DIR:-${1:-}}
ASSUME_YES=${ASSUME_YES:-0}

[ "$EUID" -eq 0 ] || { echo "Error: run as root." >&2; exit 1; }
. /etc/os-release 2>/dev/null || { echo "Error: cannot read /etc/os-release." >&2; exit 1; }
[ "${ID:-}" = debian ] || { echo "Error: this is not Debian (ID=${ID:-unknown})." >&2; exit 1; }
if [ -n "$PROFILE_DIR" ] && [ ! -r "$PROFILE_DIR/dietpi.txt" ]; then
    echo "Error: no readable dietpi.txt in profile dir '$PROFILE_DIR'." >&2
    exit 1
fi

# dietpi-installer aborts without a preset distro when there is no tty
case ${VERSION_CODENAME:-} in
    bookworm) DISTRO_TARGET=7 ;;
    trixie)   DISTRO_TARGET=8 ;;
    forky)    DISTRO_TARGET=9 ;;
    *) echo "Error: unsupported Debian release '${VERSION_CODENAME:-unknown}'." >&2; exit 1 ;;
esac

VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
case $VIRT in
    lxc|lxc-libvirt|openvz|systemd-nspawn) HW_MODEL=75 ;;
    none) HW_MODEL=21 ;;
    *) HW_MODEL=20 ;;
esac

# minimal installs ship without curl and wget
if ! command -v curl >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl ca-certificates
fi

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
if [ -n "$PROFILE_DIR" ]; then
    cp "$PROFILE_DIR/dietpi.txt" "$TMPD/dietpi.txt"
    [ ! -r "$PROFILE_DIR/Automation_Custom_Script.sh" ] || cp "$PROFILE_DIR/Automation_Custom_Script.sh" "$TMPD/Automation_Custom_Script.sh"
else
    echo "No profile given, fetching the base profile from the repo..."
    curl -fsSL "$PROFILE_URL/dietpi.txt" -o "$TMPD/dietpi.txt"
    curl -fsSL "$PROFILE_URL/Automation_Custom_Script.sh" -o "$TMPD/Automation_Custom_Script.sh"
fi

echo "This converts $PRETTY_NAME on $(hostname) to DietPi."
echo "Detected: $([ "$VIRT" = none ] && echo "bare metal" || echo "$VIRT") (HW_MODEL=$HW_MODEL), target distro $VERSION_CODENAME."
echo
echo "Everything outside the base system is removed, including user home"
echo "directories, and the SSH host keys are reset. A session as a normal"
echo "user cannot log back in. After the reboot you log in as root with the"
echo "profile password."
if ! grep -q '^AUTO_SETUP_SSH_PUBKEY=' "$TMPD/dietpi.txt"; then
    echo
    echo "WARNING: the profile has no SSH public key. On a remote machine, make"
    echo "sure you know the profile password or you will be locked out."
fi
# read the confirmation from the terminal so "curl | bash" works too
if [ "$ASSUME_YES" != 1 ]; then
    echo
    if ( : </dev/tty ) 2>/dev/null; then
        read -rp "Type YES to continue: " reply </dev/tty
    else
        echo "Error: no terminal for the confirmation, set ASSUME_YES=1 to run unattended." >&2
        exit 1
    fi
    [ "$reply" = YES ] || { echo "Aborted."; exit 1; }
fi

apt-get update
curl -fsSL "$INSTALLER_URL" -o /tmp/dietpi-installer
GITOWNER=MichaIng GITBRANCH=master HW_MODEL=$HW_MODEL DISTRO_TARGET=$DISTRO_TARGET \
    IMAGE_CREATOR=mews_se PREIMAGE_INFO="$PRETTY_NAME" WIFI_REQUIRED=0 bash /tmp/dietpi-installer
rm -f /tmp/dietpi-installer

# the conversion can remove the network stack that was in use (ifupdown2,
# netplan, cloud-init) and clears the APT lists, so make sure ifupdown and a
# DHCP client are there for the reboot
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown isc-dhcp-client

# the installer ships the stock dietpi.txt, so drop its copies of the profile
# keys and append ours (DietPi reads the first match)
while IFS= read -r line; do
    case $line in [A-Z]*=*) ;; *) continue ;; esac
    key=${line%%=*}
    sed -i "/^${key}=/d;/^#${key}=/d" /boot/dietpi.txt
done < "$TMPD/dietpi.txt"
{ echo; grep "^[A-Z0-9_]*=" "$TMPD/dietpi.txt"; } >> /boot/dietpi.txt
[ ! -r "$TMPD/Automation_Custom_Script.sh" ] || cp "$TMPD/Automation_Custom_Script.sh" /boot/Automation_Custom_Script.sh

# make the very first time sync use the profile mirror as well, the boot
# sequence syncs before the mirror in dietpi.txt is applied
mirror=$(sed -n 's/^CONFIG_NTP_MIRROR=//p' "$TMPD/dietpi.txt" | head -1)
if [ -n "$mirror" ]; then
    mkdir -p /etc/systemd/timesyncd.conf.d
    printf '[Time]\nNTP=%s\n' "$mirror" > /etc/systemd/timesyncd.conf.d/dietpi-factory.conf
fi

# install the profile key for root right away instead of waiting for the
# first boot setup, so the machine stays reachable even if that setup fails
pubkey=$(sed -n 's/^AUTO_SETUP_SSH_PUBKEY=//p' "$TMPD/dietpi.txt" | head -1)
if [ -n "$pubkey" ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    grep -qsF "$pubkey" /root/.ssh/authorized_keys || echo "$pubkey" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi


echo
echo "Done. Reboot to run DietPi's first boot setup, it finishes on its own."
echo "The network comes back as eth0 with DHCP unless the profile says otherwise."
