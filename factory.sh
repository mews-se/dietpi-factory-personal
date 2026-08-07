#!/bin/bash
# Profile generator: writes profiles/<name>/dietpi.txt plus
# Automation_Custom_Script.sh for the deployment scripts to use.
# Uses whiptail when available, plain prompts otherwise.
set -euo pipefail
cd "$(dirname "$0")"
umask 077

HAVE_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAVE_WHIPTAIL=1

ask() {
    if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
        whiptail --backtitle "dietpi-factory" --title "$1" --inputbox "$2" 10 70 "$3" 3>&1 1>&2 2>&3
    else
        local reply
        read -rp "$2 [$3]: " reply
        printf '%s\n' "${reply:-$3}"
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

askpw() {
    if [ "$HAVE_WHIPTAIL" -eq 1 ]; then
        whiptail --backtitle "dietpi-factory" --title "$1" --passwordbox "$2" 10 70 3>&1 1>&2 2>&3
    else
        local reply
        read -rsp "$2: " reply
        echo >&2
        printf '%s\n' "$reply"
    fi
}

valid_ipv4() {
    [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS=. o
    for o in $1; do [ "$o" -le 255 ] || return 1; done
}

valid_netmask() {
    valid_ipv4 "$1" || return 1
    local IFS=. o m=0
    for o in $1; do m=$(( (m << 8) | o )); done
    # the ones must be contiguous from the top
    local inv=$(( ~m & 4294967295 ))
    (( (inv & (inv + 1)) == 0 ))
}

PROFILE=$(ask "Profile" "Profile name (directory under profiles/):" "default")
[ -n "$PROFILE" ] || { echo "Error: profile name is required." >&2; exit 1; }
case $PROFILE in *[!A-Za-z0-9._-]*|.|..) echo "Error: profile name may only contain letters, digits, dot, dash and underscore." >&2; exit 1 ;; esac

CT_HOSTNAME=$(ask "Hostname" "Hostname:" "dietpi")
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] && [ ${#CT_HOSTNAME} -le 63 ] || { echo "Error: invalid hostname '$CT_HOSTNAME'." >&2; exit 1; }
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
    # firstboot applies these verbatim, bad values would leave the machine
    # without network
    [ -n "$STATIC_DNS" ] || { echo "Error: static network needs at least one DNS server." >&2; exit 1; }
    for v in "$STATIC_IP" "$STATIC_GW" $STATIC_DNS; do
        valid_ipv4 "$v" || { echo "Error: '$v' is not a valid IPv4 address." >&2; exit 1; }
    done
    valid_netmask "$STATIC_MASK" || { echo "Error: '$STATIC_MASK' is not a valid netmask." >&2; exit 1; }
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
    # a key line always contains a space, a path practically never does;
    # accept complete authorized_keys lines including options and sk- types
    case $PUBKEY_INPUT in
        *' '*) SSH_PUBKEY=$PUBKEY_INPUT ;;
        *) echo "Error: '$PUBKEY_INPUT' is not a readable file." >&2; exit 1 ;;
    esac
fi

PASSWORD=$(askpw "Password" "Global password (empty = dietpi, change after install!)")
[ -n "$PASSWORD" ] || PASSWORD=dietpi
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
    echo
    [ -z "$SOFTWARE_IDS" ] || echo "AUTO_SETUP_INSTALL_SOFTWARE_ID=$SOFTWARE_IDS"
    [ -z "$APT_PACKAGES" ] || echo "AUTO_SETUP_APT_INSTALLS=$APT_PACKAGES"
    echo
    echo "SURVEY_OPTED_IN=1"
    echo "CONFIG_NTP_MIRROR=sth1.ntp.se"
    [ -z "$SSH_PUBKEY" ] || echo "SOFTWARE_DISABLE_SSH_PASSWORD_LOGINS=root"
} > "$OUTDIR/dietpi.txt"

cp config/Automation_Custom_Script.sh "$OUTDIR/Automation_Custom_Script.sh"

# older wizard versions created world readable profiles, repair on rewrite
chmod 700 "$OUTDIR"
chmod 600 "$OUTDIR/dietpi.txt"
chmod 700 "$OUTDIR/Automation_Custom_Script.sh"

echo
echo "Profile written to $OUTDIR/"
echo "Use it with proxmox/create-dietpi-lxc.sh, or copy both files to /boot/ on a flashed DietPi image."
