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
# confirmation, WIFI=0|1 answers the WiFi question up front.
set -euo pipefail

PROFILE_URL=https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/config
PROFILE_DIR=${PROFILE_DIR:-${1:-}}
ASSUME_YES=${ASSUME_YES:-0}

resolve_dietpi_ref() {
    local sha
    sha=$(curl -fsS https://api.github.com/repos/MichaIng/DietPi/commits/master 2>/dev/null | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
    [[ $sha =~ ^[0-9a-f]{40}$ ]] && echo "$sha"
}

[ "$EUID" -eq 0 ] || { echo "Error: run as root." >&2; exit 1; }
. /etc/os-release 2>/dev/null || { echo "Error: cannot read /etc/os-release." >&2; exit 1; }
case ${ID:-} in
    debian|raspbian) ;;
    # 32-bit Raspberry Pi OS calls itself raspbian, the 64-bit one debian
    *) [[ " ${ID_LIKE:-} " == *' debian '* ]] || { echo "Error: this is not Debian (ID=${ID:-unknown})." >&2; exit 1; } ;;
esac
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

# the installer keys its bootloader and kernel choice off the hardware model
# and validates the value against the menu for the detected architecture, so
# a Raspberry Pi has to be named as one: 21 is x86 and gets rejected on ARM
HW_NAME=''
[ ! -r /proc/device-tree/model ] || HW_NAME=$(tr -d '\0' < /proc/device-tree/model)
USERLAND_ARCH=$(dpkg --print-architecture)

VIRT=$(systemd-detect-virt 2>/dev/null) || VIRT=none
case $VIRT in
    lxc|lxc-libvirt|openvz|systemd-nspawn) HW_MODEL=75 ;;
    none)
        # the 5 patterns cover the 500 and the 4 patterns the 400, same SoC
        case $HW_NAME in
            'Raspberry Pi 5'*|'Raspberry Pi Compute Module 5'*)
                if [ "$USERLAND_ARCH" = arm64 ]; then HW_MODEL=5; else HW_MODEL=4; fi ;;
            'Raspberry Pi 4'*|'Raspberry Pi Compute Module 4'*) HW_MODEL=4 ;;
            'Raspberry Pi 3'*|'Raspberry Pi Compute Module 3'*|'Raspberry Pi Zero 2'*)
                if [ "$USERLAND_ARCH" = arm64 ]; then HW_MODEL=4; else HW_MODEL=2; fi ;;
            'Raspberry Pi 2'*) HW_MODEL=2 ;;
            'Raspberry Pi'*) HW_MODEL=1 ;;
            *)
                case $USERLAND_ARCH in
                    amd64|i386) HW_MODEL=21 ;;
                    # "generic device", the installer leaves the bootloader
                    # and kernel of unlisted hardware alone
                    *) HW_MODEL=22 ;;
                esac
            ;;
        esac
    ;;
    *) HW_MODEL=20 ;;
esac

is_wireless() {
    [ -e "/sys/class/net/$1/wireless" ] || [ -e "/sys/class/net/$1/phy80211" ]
}

# the installer autoremoves everything it does not require and only then
# downloads its own packages: a link held by NetworkManager or netplan is
# already gone by that download, one held by ifupdown survives it because
# ifupdown and wpasupplicant are on the installer's own required list
ifupdown_owns() {
    [ -r /run/network/ifstate ] && grep -q "^$1=" /run/network/ifstate
}

DEFAULT_DEV=$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.*[[:blank:]]dev[[:blank:]]\{1,\}\([^[:blank:]]\{1,\}\).*/\1/p' | head -1) || DEFAULT_DEV=''
ON_WIFI=0
if [ -n "$DEFAULT_DEV" ] && is_wireless "$DEFAULT_DEV"; then ON_WIFI=1; fi

if [ "$ON_WIFI" = 1 ] && ! ifupdown_owns "$DEFAULT_DEV"; then
    echo "Error: this session runs over $DEFAULT_DEV, a wireless interface that ifupdown" >&2
    echo "does not manage. The conversion cannot survive it: the installer removes the" >&2
    echo "network stack holding the link and only afterwards downloads the packages it" >&2
    echo "needs, so the run dies offline and the machine does not come back." >&2
    echo "Convert over Ethernet, or flash an image built with scripts/bake-image.sh." >&2
    exit 1
fi

wifi_capable() {
    local d
    for d in /sys/class/net/*
    do
        if is_wireless "${d##*/}"; then return 0; fi
    done
    # a machine converted once before has no wireless interface left, its
    # firmware went out with the first run: ask the board instead
    case $HW_NAME in
        'Raspberry Pi 3'*|'Raspberry Pi 4'*|'Raspberry Pi 5'*|'Raspberry Pi Zero '*W*|'Raspberry Pi Compute Module '[45]*) return 0 ;;
    esac
    return 1
}

# dietpi-wifi.txt is sourced as bash and takes either a passphrase or a 64
# hex digit PSK as is, which is exactly how both sources below store them
wifi_slot() {
    local ssid=${2//\'/\'\\\'\'} key=${3//\'/\'\\\'\'}
    printf "aWIFI_SSID[%s]='%s'\naWIFI_KEY[%s]='%s'\naWIFI_KEYMGR[%s]='WPA-PSK'\n" "$1" "$ssid" "$1" "$key" "$1"
}

# DietPi holds five slots; NetworkManager stamps the last successful
# activation into the file, so the newest timestamp is the network in use.
# /run carries the connections rendered from netplan, which is the only
# copy a netplan managed machine has
harvest_wifi() {
    local n=0 f ssid key seen=
    while IFS= read -r f
    do
        [ -n "$f" ] || continue
        ssid=$(sed -n 's/^ssid=//p' "$f" | head -1)
        key=$(sed -n 's/^psk=//p' "$f" | head -1)
        [ -n "$ssid" ] && [ -n "$key" ] || continue
        if printf '%s\n' "$seen" | grep -qxF "$ssid"; then continue; fi
        seen=$seen$'\n'$ssid
        wifi_slot "$n" "$ssid" "$key"
        n=$((n + 1))
        [ "$n" -lt 5 ] || return 0
    done < <(
        for f in /etc/NetworkManager/system-connections/*.nmconnection /run/NetworkManager/system-connections/*.nmconnection
        do
            if [ ! -r "$f" ] || ! grep -q '^type=wifi' "$f"; then continue; fi
            printf '%s|%s\n' "$(sed -n 's/^timestamp=//p' "$f" | head -1)" "$f"
        done 2>/dev/null | sort -t'|' -k1,1nr | cut -d'|' -f2-
    )
    [ "$n" = 0 ] || return 0

    [ -r /etc/wpa_supplicant/wpa_supplicant.conf ] || return 0
    while IFS='|' read -r ssid key
    do
        [ -n "$ssid" ] && [ -n "$key" ] || continue
        wifi_slot "$n" "$ssid" "$key"
        n=$((n + 1))
        [ "$n" -lt 5 ] || return 0
    done < <(mawk '
        /^[[:space:]]*network[[:space:]]*=[[:space:]]*{/ { s = ""; k = ""; inb = 1; next }
        inb && /^[[:space:]]*}/ { if (s != "" && k != "") print s "|" k; inb = 0; next }
        inb && match($0, /^[[:space:]]*ssid[[:space:]]*=[[:space:]]*/) { s = substr($0, RLENGTH + 1); gsub(/^"|"$/, "", s); next }
        inb && match($0, /^[[:space:]]*psk[[:space:]]*=[[:space:]]*/) { k = substr($0, RLENGTH + 1); gsub(/^"|"$/, "", k); next }
    ' /etc/wpa_supplicant/wpa_supplicant.conf)
}

# a freshly booted machine often runs its own apt right away (cloud-init,
# apt-daily) and the installer dies on the dpkg lock: stop the timers and
# wait out any running job via the lock timeout on the apt calls below
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# minimal installs ship without curl and wget
if ! command -v curl >/dev/null 2>&1; then
    apt-get -o DPkg::Lock::Timeout=600 update
    apt-get -o DPkg::Lock::Timeout=600 install -y curl ca-certificates
fi

# the conversion can remove the network stack that was in use (NetworkManager,
# netplan, cloud-init), and on desktop installs the network dies with it long
# before the run ends: put ifupdown and a DHCP client in place now, while apt
# still has a network, and abort before anything destructive if that fails
DHCP_PKG=isc-dhcp-client
[ "$DISTRO_TARGET" -lt 9 ] || DHCP_PKG=dhcpcd-base
if [ "$(dpkg-query -W -f='${db:Status-Abbrev}\n' ifupdown "$DHCP_PKG" 2>/dev/null | grep -c '^ii')" -ne 2 ]; then
    if ! { apt-get -o DPkg::Lock::Timeout=600 update -q && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y ifupdown "$DHCP_PKG"; }; then
        echo "Error: could not install ifupdown and $DHCP_PKG, the network would not survive the conversion. Fix APT and retry." >&2
        exit 1
    fi
fi

# pin the run to one resolved master commit so the installer script and its
# GITBRANCH checkout cannot drift apart, and fail on it before the operator
# has confirmed anything
DIETPI_REF=$(resolve_dietpi_ref) || { echo "Error: could not resolve the DietPi master commit, check the network and retry." >&2; exit 1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
if [ -n "$PROFILE_DIR" ]; then
    cp "$PROFILE_DIR/dietpi.txt" "$TMPD/dietpi.txt"
    [ ! -r "$PROFILE_DIR/Automation_Custom_Script.sh" ] || cp "$PROFILE_DIR/Automation_Custom_Script.sh" "$TMPD/Automation_Custom_Script.sh"
    [ ! -r "$PROFILE_DIR/dietpi-wifi.txt" ] || cp "$PROFILE_DIR/dietpi-wifi.txt" "$TMPD/dietpi-wifi.txt"
else
    echo "No profile given, fetching the base profile from the repo..."
    curl -fsSL "$PROFILE_URL/dietpi.txt" -o "$TMPD/dietpi.txt"
    curl -fsSL "$PROFILE_URL/Automation_Custom_Script.sh" -o "$TMPD/Automation_Custom_Script.sh"
fi

# a profile saved with Windows line endings would ride a stray \r into
# every value, DietPi applies them verbatim
for pfile in "$TMPD/dietpi.txt" "$TMPD/Automation_Custom_Script.sh" "$TMPD/dietpi-wifi.txt"; do
    [ -r "$pfile" ] || continue
    if grep -q $'\r' "$pfile"; then
        echo "Error: ${pfile##*/} has Windows (CRLF) line endings, convert it with e.g. dos2unix." >&2
        exit 1
    fi
done

# upstream treats the key as a URL field and a bundled script runs on file
# presence alone, hence drop a legacy boolean or refuse it without a script
CSX=$(sed -n '/^[[:blank:]]*AUTO_SETUP_CUSTOM_SCRIPT_EXEC=/{s/^[^=]*=//p;q}' "$TMPD/dietpi.txt")
if [ "$CSX" = 1 ]; then
    if [ -r "$TMPD/Automation_Custom_Script.sh" ]; then
        echo "Note: dropping legacy AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1, the bundled script runs on its own."
        sed -i '/^AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1[[:blank:]]*$/d' "$TMPD/dietpi.txt"
    else
        echo "Error: AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1 is not a valid URL and the profile has no Automation_Custom_Script.sh." >&2
        exit 1
    fi
fi

# validate the whole profile before doing anything destructive
grep -qE '^[A-Z][A-Z0-9_]*=' "$TMPD/dietpi.txt" || { echo "Error: the profile contains no valid KEY=value lines." >&2; exit 1; }
BAD=$(grep -vE '^[A-Z][A-Z0-9_]*=|^#|^[[:space:]]*$' "$TMPD/dietpi.txt" || true)
[ -z "$BAD" ] || { printf 'Error: invalid profile lines:\n%s\n' "$BAD" >&2; exit 1; }

echo "This converts $PRETTY_NAME on $(hostname) to DietPi."
echo "Detected: ${HW_NAME:-$([ "$VIRT" = none ] && echo "bare metal" || echo "$VIRT")} (HW_MODEL=$HW_MODEL), target distro $VERSION_CODENAME."

# the installer either installs the whole WiFi stack or purges it, with
# nothing in between, and it purges whatever manages the network today: a
# wireless machine that skips WiFi loses its only link mid-run. Settle this
# before the confirmation and carry the credentials over, since installing
# wpasupplicant without them reconnects to nothing. A link this run cannot
# survive at all was already refused above.
WIFI=${WIFI:-}
if [ "$HW_MODEL" = 20 ] || [ "$HW_MODEL" = 75 ]; then
    # the installer forces WiFi off for virtual machines and containers anyway
    WIFI=0
elif [ -z "$WIFI" ]; then
    if ! wifi_capable; then
        WIFI=0
    elif [ "$ASSUME_YES" = 1 ] || ! ( : </dev/tty ) 2>/dev/null; then
        # unattended: never take the link away from a machine that is using it
        WIFI=$ON_WIFI
    else
        echo
        if [ "$ON_WIFI" = 1 ]; then
            echo "This session runs over $DEFAULT_DEV, a wireless interface. Without WiFi"
            echo "support the machine goes offline during the conversion and needs an"
            echo "Ethernet cable to come back."
            WIFI_DEFAULT=y
        else
            echo "WiFi support pulls in around 380 MiB of firmware packages."
            WIFI_DEFAULT=n
        fi
        read -rp "Install WiFi support? [$WIFI_DEFAULT]: " reply </dev/tty
        [ -n "$reply" ] || reply=$WIFI_DEFAULT
        case $reply in [Yy]*) WIFI=1 ;; *) WIFI=0 ;; esac
    fi
fi
case $WIFI in
    0) echo "WiFi support: disabled" ;;
    1) echo "WiFi support: enabled" ;;
    *) echo "Error: WIFI must be 0 or 1, got '$WIFI'." >&2; exit 1 ;;
esac

WIFI_COUNTRY=''
if [ "$WIFI" = 1 ]; then
    [ -s "$TMPD/dietpi-wifi.txt" ] || harvest_wifi > "$TMPD/dietpi-wifi.txt"
    if [ "$ON_WIFI" = 1 ] && [ ! -s "$TMPD/dietpi-wifi.txt" ] && { [ "$ASSUME_YES" = 1 ] || ! ( : </dev/tty ) 2>/dev/null; }; then
        echo "Error: no WiFi credentials found to carry over, and this session runs" >&2
        echo "over $DEFAULT_DEV. The machine would not come back after the conversion." >&2
        echo "Put the SSID and key in the profile as dietpi-wifi.txt, or run this" >&2
        echo "interactively to decide at the prompt." >&2
        exit 1
    fi
    # a wrong regulatory domain silently costs the 5 GHz channels
    if [ -r /etc/wpa_supplicant/wpa_supplicant.conf ]; then
        WIFI_COUNTRY=$(sed -n 's/^[[:blank:]]*country=//p' /etc/wpa_supplicant/wpa_supplicant.conf | head -1)
    fi
    if [ -z "$WIFI_COUNTRY" ] && command -v iw > /dev/null; then
        WIFI_COUNTRY=$(iw reg get | sed -n 's/^country \([A-Z][A-Z]\):.*/\1/p' | head -1) || WIFI_COUNTRY=''
    fi
fi

echo
echo "Everything outside the base system is removed, including user home"
echo "directories, and the SSH host keys are reset. A session as a normal"
echo "user cannot log back in. After the reboot you log in as root with the"
echo "profile password."
# an empty AUTO_SETUP_SSH_PUBKEY= line must not silence the warning
pubkey=$(sed -n 's/^AUTO_SETUP_SSH_PUBKEY=//p' "$TMPD/dietpi.txt" | head -1)
if [ -z "$pubkey" ]; then
    echo
    echo "WARNING: the profile has no SSH public key. On a remote machine, make"
    echo "sure you know the profile password or you will be locked out."
fi
if [ "$ON_WIFI" = 1 ] && [ "$WIFI" = 0 ]; then
    echo
    echo "WARNING: this session runs over $DEFAULT_DEV and WiFi support is being"
    echo "removed. The machine drops off the network the moment the old network"
    echo "stack is purged, and needs an Ethernet cable to come back."
fi
if [ "$WIFI" = 1 ] && [ ! -s "$TMPD/dietpi-wifi.txt" ]; then
    echo
    echo "WARNING: no WiFi credentials found to carry over. The packages get"
    echo "installed but the machine reconnects to nothing; put the SSID and key"
    echo "into /boot/dietpi-wifi.txt before rebooting."
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

# this update also waits out any apt job the installer would collide with
apt-get -o DPkg::Lock::Timeout=600 update
curl -fsSL "https://raw.githubusercontent.com/MichaIng/DietPi/$DIETPI_REF/.build/images/dietpi-installer" -o "$TMPD"/dietpi-installer
GITOWNER=MichaIng GITBRANCH=$DIETPI_REF HW_MODEL=$HW_MODEL DISTRO_TARGET=$DISTRO_TARGET \
    IMAGE_CREATOR=mews_se PREIMAGE_INFO="$PRETTY_NAME" WIFI_REQUIRED=$WIFI bash "$TMPD"/dietpi-installer || {
    echo "Error: dietpi-installer failed. The system may be partially stripped." >&2
    echo "Fix the cause above and run this script again, do not reboot as is." >&2
    exit 1
}
rm -f "$TMPD"/dietpi-installer

# the installer stamps the pinned SHA as the permanent dietpi-update target,
# which would freeze updates at this commit, point updates back at master
sed -i 's/^DEV_GITBRANCH=.*/DEV_GITBRANCH=master/' /boot/dietpi.txt

# dietpi-software initialises Dropbear as pre-installed although containers
# never ship it, which makes the first run skip the SSH server.
# Fixed upstream in dev (MichaIng/DietPi@4a26253): the installer now seeds
# the state file itself, so only add the line while master still lacks it
if [ "$HW_MODEL" = 75 ]; then
    grep -q 'aSOFTWARE_INSTALL_STATE\[104\]=' /boot/dietpi/.installed 2>/dev/null || echo 'aSOFTWARE_INSTALL_STATE[104]=0' >> /boot/dietpi/.installed
fi

# the installer ships the stock dietpi.txt, so drop its copies of the profile
# keys and append ours (DietPi reads the first match); profile and SSH key go
# in before anything that needs the network again, a failure further down
# must not leave the machine unconfigured or unreachable
if [ "$WIFI" = 1 ]; then
    # DietPi gives WiFi priority at first boot and disables Ethernet, which
    # is what a wireless machine needs; the base profile says the opposite
    sed -i '/^AUTO_SETUP_NET_WIFI_ENABLED=/d' "$TMPD/dietpi.txt"
    echo 'AUTO_SETUP_NET_WIFI_ENABLED=1' >> "$TMPD/dietpi.txt"
    if [ -n "$WIFI_COUNTRY" ]; then
        sed -i '/^AUTO_SETUP_NET_WIFI_COUNTRY_CODE=/d' "$TMPD/dietpi.txt"
        echo "AUTO_SETUP_NET_WIFI_COUNTRY_CODE=$WIFI_COUNTRY" >> "$TMPD/dietpi.txt"
    fi
    if [ -s "$TMPD/dietpi-wifi.txt" ]; then
        # overwrites the empty one the installer generates
        cp "$TMPD/dietpi-wifi.txt" /boot/dietpi-wifi.txt
        chmod 600 /boot/dietpi-wifi.txt
    fi
fi

while IFS= read -r line; do
    [[ $line =~ ^[A-Z][A-Z0-9_]*= ]] || continue
    key=${line%%=*}
    sed -i "/^${key}=/d;/^#${key}=/d" /boot/dietpi.txt
done < "$TMPD/dietpi.txt"
{ echo; grep -E '^[A-Z][A-Z0-9_]*=' "$TMPD/dietpi.txt"; } >> /boot/dietpi.txt
[ ! -r "$TMPD/Automation_Custom_Script.sh" ] || cp "$TMPD/Automation_Custom_Script.sh" /boot/Automation_Custom_Script.sh

# make the very first time sync use the profile mirror as well, the boot
# sequence syncs before the mirror in dietpi.txt is applied
mirror=$(sed -n 's/^CONFIG_NTP_MIRROR=//p' "$TMPD/dietpi.txt" | head -1)
if [ -n "$mirror" ]; then
    mkdir -p /etc/systemd/timesyncd.conf.d
    # the empty NTP= resets the list, systemd appends list settings across files
    printf '[Time]\nNTP=\nNTP=%s\nFallbackNTP=sth1.ntp.se\n' "$mirror" > /etc/systemd/timesyncd.conf.d/dietpi-factory.conf
fi

# install the profile key for root right away instead of waiting for the
# first boot setup, so the machine stays reachable even if that setup fails
if [ -n "$pubkey" ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    grep -qsF "$pubkey" /root/.ssh/authorized_keys || echo "$pubkey" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# ifupdown and the DHCP client were put in place before the installer ran,
# but verify they survived the conversion - no apt here, the network may
# already be gone (the purge takes NetworkManager with it on desktops)
if [ "$(dpkg-query -W -f='${db:Status-Abbrev}\n' ifupdown "$DHCP_PKG" 2>/dev/null | grep -c '^ii')" -ne 2 ]; then
    echo "Error: ifupdown or $DHCP_PKG went missing during the conversion. Do not" >&2
    echo "reboot yet, the network would not come back. Install them manually first." >&2
    exit 1
fi


echo
echo "Done. Reboot to run DietPi's first boot setup, it finishes on its own."
if [ "$WIFI" = 1 ] && [ -s "$TMPD/dietpi-wifi.txt" ]; then
    echo "The network comes back on WiFi with the credentials carried over."
else
    echo "The network comes back as eth0 with DHCP unless the profile says otherwise."
fi
# the MAC survives the conversion, the hostname and lease may not; sysfs is
# read directly, this late nothing but the base system can be relied upon
MAC=''
for f in /sys/class/net/*/address; do
    case $f in */lo/*) continue ;; esac
    MAC=$(cat "$f" 2>/dev/null) || continue
    break
done
if [ -n "$MAC" ]; then
    echo "Find the machine after the reboot by MAC $MAC in your ARP or DHCP lease table."
fi
