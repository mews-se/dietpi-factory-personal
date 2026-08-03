#!/bin/bash
# Profile generator: writes profiles/<name>/dietpi.txt plus
# Automation_Custom_Script.sh for the deployment scripts to use.
# Uses whiptail when available, plain prompts otherwise.
set -euo pipefail
cd "$(dirname "$0")"

HAVE_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAVE_WHIPTAIL=1

ask() {
    if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
        whiptail --backtitle "dietpi-factory" --title "$1" --inputbox "$2" 10 70 "$3" 3>&1 1>&2 2>&3
    else
        local reply
        read -rp "$2 [$3]: " reply
        echo "${reply:-$3}"
    fi
}

confirm() {
    if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
        whiptail --backtitle "dietpi-factory" --title "$1" --yesno "$2" 9 70
    else
        local reply
        read -rp "$2 [Y/n]: " reply
        case $reply in [Nn]*) return 1 ;; *) return 0 ;; esac
    fi
}

PROFILE=$(ask "Profile" "Profile name (directory under profiles/):" "default")
[ -n "$PROFILE" ] || { echo "Error: profile name is required." >&2; exit 1; }

CT_HOSTNAME=$(ask "Hostname" "Hostname:" "dietpi")
TIMEZONE=$(ask "Timezone" "Timezone:" "Europe/Stockholm")
KEYBOARD=$(ask "Keyboard" "Keyboard layout:" "se")
LOCALE=$(ask "Locale" "Locale:" "en_US.UTF-8")

USESTATIC=0 STATIC_IP='' STATIC_MASK='' STATIC_GW='' STATIC_DNS=''
if ! confirm "Network" "Use DHCP? (No = static IP)"; then
    USESTATIC=1
    STATIC_IP=$(ask "Static IP" "IP address:" "")
    STATIC_MASK=$(ask "Netmask" "Netmask:" "255.255.255.0")
    STATIC_GW=$(ask "Gateway" "Gateway:" "")
    STATIC_DNS=$(ask "DNS" "DNS server(s), space separated:" "9.9.9.9 149.112.112.112")
fi

DEFAULT_PUBKEY_FILE=""
for f in "$HOME"/.ssh/id_ed25519.pub "$HOME"/.ssh/id_rsa.pub; do
    [ -r "$f" ] && { DEFAULT_PUBKEY_FILE=$f; break; }
done
PUBKEY_INPUT=$(ask "SSH key" "Public key (path to .pub file, pasted key, or empty to skip):" "$DEFAULT_PUBKEY_FILE")
SSH_PUBKEY=""
if [ -r "$PUBKEY_INPUT" ]; then
    SSH_PUBKEY=$(head -n1 "$PUBKEY_INPUT")
elif [ -n "$PUBKEY_INPUT" ]; then
    case $PUBKEY_INPUT in
        ssh-*|ecdsa-*) SSH_PUBKEY=$PUBKEY_INPUT ;;
        *) echo "Warning: '$PUBKEY_INPUT' is neither a readable file nor an SSH key, skipping." >&2 ;;
    esac
fi

PASSWORD=$(ask "Password" "Global password (change after install!):" "dietpi")
SOFTWARE_IDS=$(ask "DietPi software" "dietpi-software IDs, space separated (see https://dietpi.com/docs/software/):" "")
APT_PACKAGES=$(ask "APT packages" "Extra APT packages, space separated:" "")

OUTDIR=profiles/$PROFILE
mkdir -p "$OUTDIR"

{
    echo "# dietpi-factory profile: $PROFILE"
    echo
    echo "AUTO_SETUP_LOCALE=$LOCALE"
    echo "AUTO_SETUP_KEYBOARD_LAYOUT=$KEYBOARD"
    echo "AUTO_SETUP_TIMEZONE=$TIMEZONE"
    echo
    echo "AUTO_SETUP_NET_ETHERNET_ENABLED=1"
    echo "AUTO_SETUP_NET_WIFI_ENABLED=0"
    echo "AUTO_SETUP_NET_HOSTNAME=$CT_HOSTNAME"
    echo "AUTO_SETUP_BOOT_WAIT_FOR_NETWORK=1"
    echo "AUTO_SETUP_NET_USESTATIC=$USESTATIC"
    if [ "$USESTATIC" = 1 ]; then
        echo "AUTO_SETUP_NET_STATIC_IP=$STATIC_IP"
        echo "AUTO_SETUP_NET_STATIC_MASK=$STATIC_MASK"
        echo "AUTO_SETUP_NET_STATIC_GATEWAY=$STATIC_GW"
        echo "AUTO_SETUP_NET_STATIC_DNS=$STATIC_DNS"
    fi
    echo
    echo "AUTO_SETUP_AUTOSTART_TARGET_INDEX=0"
    echo "AUTO_SETUP_SSH_SERVER_INDEX=-2"
    [ -z "$SSH_PUBKEY" ] || echo "AUTO_SETUP_SSH_PUBKEY=$SSH_PUBKEY"
    echo
    echo "AUTO_SETUP_AUTOMATED=1"
    echo "AUTO_SETUP_GLOBAL_PASSWORD=$PASSWORD"
    echo "AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1"
    echo
    [ -z "$SOFTWARE_IDS" ] || echo "AUTO_SETUP_INSTALL_SOFTWARE_ID=$SOFTWARE_IDS"
    [ -z "$APT_PACKAGES" ] || echo "AUTO_SETUP_APT_INSTALLS=$APT_PACKAGES"
    echo
    echo "SURVEY_OPTED_IN=1"
    echo "CONFIG_NTP_MIRROR=sth1.ntp.se"
    [ -z "$SSH_PUBKEY" ] || echo "SOFTWARE_DISABLE_SSH_PASSWORD_LOGINS=root"
} > "$OUTDIR/dietpi.txt"

cp config/Automation_Custom_Script.sh "$OUTDIR/Automation_Custom_Script.sh"

echo
echo "Profile written to $OUTDIR/"
echo "Use it with proxmox/create-dietpi-lxc.sh, or copy both files to /boot/ on a flashed DietPi image."
