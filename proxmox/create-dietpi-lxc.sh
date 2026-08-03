#!/bin/bash
# Create a DietPi LXC container on Proxmox VE. Run on the PVE host:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/proxmox/create-dietpi-lxc.sh)"
#
# Pass a factory.sh profile directory as first argument (or PROFILE_DIR) to
# use it instead of the embedded defaults. ASSUME_DEFAULTS=1 skips all dialogs.
set -euo pipefail

INSTALLER_URL=https://raw.githubusercontent.com/MichaIng/DietPi/master/.build/images/dietpi-installer
PROFILE_DIR=${PROFILE_DIR:-${1:-}}
ASSUME_DEFAULTS=${ASSUME_DEFAULTS:-0}

command -v pct >/dev/null 2>&1 || { echo "Error: must be run on a Proxmox VE host." >&2; exit 1; }
[ "$ASSUME_DEFAULTS" = 1 ] || command -v whiptail >/dev/null 2>&1 || { echo "Error: whiptail not found." >&2; exit 1; }
if [ -n "$PROFILE_DIR" ] && [ ! -r "$PROFILE_DIR/dietpi.txt" ]; then
    echo "Error: no readable dietpi.txt in profile dir '$PROFILE_DIR'." >&2
    exit 1
fi

ask() {
    if [ "$ASSUME_DEFAULTS" = 1 ]; then echo "$3"; return; fi
    whiptail --backtitle "dietpi-factory" --title "$1" --inputbox "$2" 10 60 "$3" 3>&1 1>&2 2>&3
}

CTID=$(ask "Container ID" "Container ID:" "$(pvesh get /cluster/nextid)")
CT_HOSTNAME=$(ask "Hostname" "Container hostname:" "dietpi")
CORES=$(ask "CPU" "Number of cores:" "2")
RAM=$(ask "Memory" "RAM in MiB:" "1024")
DISK=$(ask "Disk" "Root disk size in GiB:" "8")
BRIDGE=$(ask "Network" "Bridge:" "vmbr0")

if [ "$ASSUME_DEFAULTS" = 1 ]; then
    # the storage with the most free space
    STORAGE=$(pvesm status --content rootdir | awk 'NR>1' | sort -k6 -n | tail -1 | awk '{print $1}')
    NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
else
    STORAGE_OPTS=()
    while read -r name; do STORAGE_OPTS+=("$name" ""); done < <(pvesm status --content rootdir | awk 'NR>1 {print $1}')
    STORAGE=$(whiptail --backtitle "dietpi-factory" --title "Storage" \
        --menu "Storage for the container root disk:" 16 60 8 "${STORAGE_OPTS[@]}" 3>&1 1>&2 2>&3)

    if whiptail --backtitle "dietpi-factory" --title "Network" --yesno "Use DHCP? (No = static IP)" 9 60; then
        NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
    else
        IPCIDR=$(ask "Static IP" "IP address with CIDR (e.g. 10.0.0.50/24):" "")
        GW=$(ask "Gateway" "Gateway:" "")
        NET0="name=eth0,bridge=${BRIDGE},ip=${IPCIDR},gw=${GW}"
    fi
fi

echo "Looking up latest Debian standard template..."
pveam update >/dev/null
TEMPLATE=$(pveam available --section system | awk '/debian-1[23]-standard/ {print $2}' | sort -V | tail -1)
[ -n "$TEMPLATE" ] || { echo "Error: no Debian standard template found via pveam." >&2; exit 1; }
pveam download local "$TEMPLATE" || true

# dietpi-installer aborts without a preset distro when there is no tty
case $TEMPLATE in
    *debian-13*) DISTRO_TARGET=8 ;;
    *debian-12*) DISTRO_TARGET=7 ;;
    *) echo "Error: cannot map template '$TEMPLATE' to a DietPi distro target." >&2; exit 1 ;;
esac

echo "Creating container ${CTID} (${CT_HOSTNAME})..."
pct create "$CTID" "local:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$NET0" \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype debian \
    --onboot 1

pct start "$CTID"
echo "Waiting for network in the container..."
for _ in $(seq 1 30); do
    pct exec "$CTID" -- ping -c1 -W1 deb.debian.org >/dev/null 2>&1 && break
    sleep 2
done

echo "Converting Debian to DietPi, this takes a while..."
pct exec "$CTID" -- bash -c "apt-get update && apt-get install -y curl ca-certificates"
pct exec "$CTID" -- bash -c "curl -fsSL '${INSTALLER_URL}' -o /tmp/dietpi-installer && \
    GITOWNER=MichaIng GITBRANCH=master HW_MODEL=75 DISTRO_TARGET=${DISTRO_TARGET} IMAGE_CREATOR=mews_se \
    PREIMAGE_INFO='Debian LXC template' WIFI_REQUIRED=0 bash /tmp/dietpi-installer"

# the conversion removes ifupdown2 from the template and clears the APT lists
echo "Installing ifupdown..."
pct exec "$CTID" -- bash -c "apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown isc-dhcp-client"

echo "Applying profile..."
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
if [ -n "$PROFILE_DIR" ]; then
    cp "$PROFILE_DIR/dietpi.txt" "$TMPD/dietpi.txt"
    [ ! -r "$PROFILE_DIR/Automation_Custom_Script.sh" ] || cp "$PROFILE_DIR/Automation_Custom_Script.sh" "$TMPD/Automation_Custom_Script.sh"
else
    sed "s/__HOSTNAME__/${CT_HOSTNAME}/" > "$TMPD/dietpi.txt" <<'EOF'
AUTO_SETUP_LOCALE=en_US.UTF-8
AUTO_SETUP_KEYBOARD_LAYOUT=se
AUTO_SETUP_TIMEZONE=Europe/Stockholm
AUTO_SETUP_NET_ETHERNET_ENABLED=1
AUTO_SETUP_NET_WIFI_ENABLED=0
AUTO_SETUP_NET_USESTATIC=0
AUTO_SETUP_NET_HOSTNAME=__HOSTNAME__
AUTO_SETUP_BOOT_WAIT_FOR_NETWORK=1
AUTO_SETUP_AUTOSTART_TARGET_INDEX=0
AUTO_SETUP_SSH_SERVER_INDEX=-2
AUTO_SETUP_AUTOMATED=1
AUTO_SETUP_GLOBAL_PASSWORD=dietpi
AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1
SURVEY_OPTED_IN=1
CONFIG_NTP_MIRROR=sth1.ntp.se
EOF
    cat > "$TMPD/Automation_Custom_Script.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
apt-get update
apt-get install -y git
for i in $(seq 0 20); do
    case $i in 0|1|2|5|6|7|17|18|20) echo "aENABLED[$i]=1" ;; *) echo "aENABLED[$i]=0" ;; esac
done > /boot/dietpi/.dietpi-banner
cat > /etc/profile.d/99-hostctl-firstlogin.sh <<'HOOK'
if [ -n "${PS1:-}" ] && [ "$(id -u)" -ne 0 ] && [ ! -e /var/local/hostctl-firstlogin-done ]; then
    if [ ! -d "$HOME/hostctl" ]; then
        git clone https://github.com/mews-se/hostctl.git "$HOME/hostctl"
    fi
    if sudo bash "$HOME/hostctl/hostctl.sh"; then
        sudo touch /var/local/hostctl-firstlogin-done
        sudo rm -f /etc/profile.d/99-hostctl-firstlogin.sh
    fi
fi
HOOK
EOF
fi

# the installer ships the stock dietpi.txt, so drop its copies of the profile
# keys and append ours (DietPi reads the first match)
pct push "$CTID" "$TMPD/dietpi.txt" /boot/dietpi-factory.txt
[ ! -r "$TMPD/Automation_Custom_Script.sh" ] || pct push "$CTID" "$TMPD/Automation_Custom_Script.sh" /boot/Automation_Custom_Script.sh
pct exec "$CTID" -- bash -c '
    while IFS= read -r line; do
        case $line in [A-Z]*=*) ;; *) continue ;; esac
        key=${line%%=*}
        sed -i "/^${key}=/d;/^#${key}=/d" /boot/dietpi.txt
    done < /boot/dietpi-factory.txt
    { echo; grep "^[A-Z0-9_]*=" /boot/dietpi-factory.txt; } >> /boot/dietpi.txt
    rm /boot/dietpi-factory.txt'

# pct reboot right after the conversion does not take effect, stop/start does
echo "Restarting container..."
pct stop "$CTID"
pct start "$CTID"

echo
echo "Done. Container ${CTID} finishes its DietPi first run setup on its own."
echo "Follow along with: pct console ${CTID}"
