#!/bin/bash
# Create a DietPi LXC container on Proxmox VE. Run on the PVE host:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/proxmox/create-dietpi-lxc.sh)"
#
# Pass a factory.sh profile directory as first argument (or PROFILE_DIR) to
# use it instead of the embedded defaults. ASSUME_DEFAULTS=1 skips all dialogs.
set -euo pipefail

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

require_uint() {
    case $2 in ''|*[!0-9]*|0[0-9]*) echo "Error: $1 '$2' is not a plain number." >&2; exit 1 ;; esac
    [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || { echo "Error: $1 must be between $3 and $4." >&2; exit 1; }
}

valid_ipv4() {
    [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS=. o
    for o in $1; do [ "$o" -le 255 ] || return 1; done
}

resolve_dietpi_ref() {
    local sha
    sha=$(curl -fsS https://api.github.com/repos/MichaIng/DietPi/commits/master 2>/dev/null | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
    [[ $sha =~ ^[0-9a-f]{40}$ ]] && echo "$sha"
}


CTID=$(ask "Container ID" "Container ID:" "$(pvesh get /cluster/nextid)")
CT_HOSTNAME=$(ask "Hostname" "Container hostname:" "dietpi")
CORES=$(ask "CPU" "Number of cores:" "2")
RAM=$(ask "Memory" "RAM in MiB:" "1024")
DISK=$(ask "Disk" "Root disk size in GiB:" "8")
BRIDGE=$(ask "Network" "Bridge:" "vmbr0")

require_uint "container ID" "$CTID" 100 999999999
require_uint "cores" "$CORES" 1 256
require_uint "RAM" "$RAM" 128 4194304
require_uint "disk size" "$DISK" 1 65536
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] && [ ${#CT_HOSTNAME} -le 63 ] || { echo "Error: invalid hostname '$CT_HOSTNAME'." >&2; exit 1; }

# fail early on a taken ID, pct create remains the authoritative check;
# capture first so grep -q cannot close the pipe early under pipefail
CLUSTER_GUESTS=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || true)
if grep -Eq "\"vmid\":[[:space:]]*${CTID}[,}]" <<< "$CLUSTER_GUESTS"; then
    echo "Error: ID $CTID is already in use." >&2
    exit 1
fi

if [ "$ASSUME_DEFAULTS" = 1 ]; then
    # the storage with the most free space
    STORAGE=$(pvesm status --content rootdir | awk 'NR>1 && $3=="active"' | sort -k6 -n | tail -1 | awk '{print $1}')
    NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
else
    STORAGE_OPTS=()
    while read -r name; do STORAGE_OPTS+=("$name" ""); done < <(pvesm status --content rootdir | awk 'NR>1 && $3=="active" {print $1}')
    [ ${#STORAGE_OPTS[@]} -gt 0 ] || { echo "Error: no active storage with container support found." >&2; exit 1; }
    STORAGE=$(whiptail --backtitle "dietpi-factory" --title "Storage" \
        --menu "Storage for the container root disk:" 16 60 8 "${STORAGE_OPTS[@]}" 3>&1 1>&2 2>&3)

    if whiptail --backtitle "dietpi-factory" --title "Network" --yesno "Use DHCP? (No = static IP)" 9 60; then
        NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
    else
        IPCIDR=$(ask "Static IP" "IP address with CIDR (e.g. 10.0.0.50/24):" "")
        GW=$(ask "Gateway" "Gateway:" "")
        [[ $IPCIDR == */* ]] && valid_ipv4 "${IPCIDR%/*}" && [ "${IPCIDR#*/}" -ge 0 ] 2>/dev/null && [ "${IPCIDR#*/}" -le 32 ] 2>/dev/null || \
            { echo "Error: the static IP must be address/prefix, e.g. 10.0.0.50/24." >&2; exit 1; }
        valid_ipv4 "$GW" || { echo "Error: the gateway must be a valid IPv4 address." >&2; exit 1; }
        NET0="name=eth0,bridge=${BRIDGE},ip=${IPCIDR},gw=${GW}"
    fi
fi

TMPD=$(mktemp -d)
CT_CREATED=0 HANDOFF=0
cleanup() {
    set +e
    if [ "$CT_CREATED" = 1 ] && [ "$HANDOFF" = 0 ]; then
        # a destroy racing the tail end of a failed start can leave the
        # config behind, verify and retry
        for _ in 1 2 3; do
            pct destroy "$CTID" --purge --force >/dev/null 2>&1
            pct config "$CTID" >/dev/null 2>&1 || break
            sleep 3
        done
        if pct config "$CTID" >/dev/null 2>&1; then
            echo "Warning: container $CTID could not be removed, inspect with: pct config $CTID" >&2
        fi
    fi
    rm -rf "$TMPD"
}
trap cleanup EXIT

if [ -n "$PROFILE_DIR" ]; then
    cp "$PROFILE_DIR/dietpi.txt" "$TMPD/dietpi.txt"
    [ ! -r "$PROFILE_DIR/Automation_Custom_Script.sh" ] || cp "$PROFILE_DIR/Automation_Custom_Script.sh" "$TMPD/Automation_Custom_Script.sh"
else
    cat > "$TMPD/dietpi.txt" <<'EOF'
AUTO_SETUP_LOCALE=en_US.UTF-8
AUTO_SETUP_KEYBOARD_LAYOUT=se
AUTO_SETUP_TIMEZONE=Europe/Stockholm
AUTO_SETUP_NET_ETHERNET_ENABLED=1
AUTO_SETUP_NET_WIFI_ENABLED=0
AUTO_SETUP_NET_USESTATIC=0
AUTO_SETUP_BOOT_WAIT_FOR_NETWORK=1
AUTO_SETUP_AUTOSTART_TARGET_INDEX=0
AUTO_SETUP_SSH_SERVER_INDEX=-2
AUTO_SETUP_AUTOMATED=1
AUTO_SETUP_GLOBAL_PASSWORD=dietpi
SURVEY_OPTED_IN=1
CONFIG_NTP_MIRROR=sth1.ntp.se
EOF
    echo "AUTO_SETUP_NET_HOSTNAME=$CT_HOSTNAME" >> "$TMPD/dietpi.txt"
    # kept byte-identical with config/Automation_Custom_Script.sh and the
    # create-dietpi-vm.sh copy, quoted so nothing expands on the PVE host
    cat > "$TMPD/Automation_Custom_Script.sh" <<'CSEOF'
#!/bin/bash
# Runs once at the end of DietPi's automated first boot when copied to /boot.
set -euo pipefail

exec > >(tee -a /var/tmp/dietpi-factory-firstboot.log) 2>&1

# a transient mirror hiccup should not fail the whole first boot
for i in 1 2 3; do
    if apt-get update && apt-get install -y git; then break; fi
    sleep 10
done

# banner layout: device model, uptime, CPU temp, LAN/WAN IP, disk, RAM,
# load average and kernel
for i in $(seq 0 20); do
    case $i in 0|1|2|5|6|7|17|18|20) echo "aENABLED[$i]=1" ;; *) echo "aENABLED[$i]=0" ;; esac
done > /boot/dietpi/.dietpi-banner

# fetch a pinned hostctl at the first interactive login, then remove the
# hook; an existing ~/hostctl is never touched and a missing git heals later
cat > /etc/profile.d/99-hostctl-firstlogin.sh <<'HOOK'
if [ -n "${PS1:-}" ] && [ "$(id -u)" -ne 0 ] && [ ! -e /var/local/hostctl-firstlogin-done ]; then
    command -v git >/dev/null 2>&1 || sudo apt-get install -y git
    if [ ! -e "$HOME/hostctl" ]; then
        _t=$(mktemp -d)
        if git clone -q https://github.com/mews-se/hostctl.git "$_t/hostctl" &&
            git -C "$_t/hostctl" checkout -q 76340ec6b869ced52bd3099daf5222ca10d409f9 &&
            [ "$(git -C "$_t/hostctl" rev-parse HEAD)" = 76340ec6b869ced52bd3099daf5222ca10d409f9 ]; then
            mv "$_t/hostctl" "$HOME/hostctl"
        fi
        rm -rf "$_t"
        unset _t
    fi
    if [ -d "$HOME/hostctl/.git" ]; then
        if sudo bash "$HOME/hostctl/hostctl.sh"; then
            sudo touch /var/local/hostctl-firstlogin-done
            sudo rm -f /etc/profile.d/99-hostctl-firstlogin.sh
        fi
    else
        echo "hostctl: $HOME/hostctl exists but is not the expected clone, move it aside and log in again."
    fi
fi
HOOK
CSEOF
fi

# a profile saved with Windows line endings would ride a stray \r into
# every value, DietPi applies them verbatim
if grep -q $'\r' "$TMPD/dietpi.txt"; then
    echo "Error: the profile has Windows (CRLF) line endings, convert it with e.g. dos2unix." >&2
    exit 1
fi

# upstream treats the key as an URL field and a bundled script runs on file
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

# validate the whole profile before anything is created or converted
grep -qE '^[A-Z][A-Z0-9_]*=' "$TMPD/dietpi.txt" || { echo "Error: the profile contains no valid KEY=value lines." >&2; exit 1; }
BAD=$(grep -vE '^[A-Z][A-Z0-9_]*=|^#|^[[:space:]]*$' "$TMPD/dietpi.txt" || true)
[ -z "$BAD" ] || { printf 'Error: invalid profile lines:\n%s\n' "$BAD" >&2; exit 1; }

echo "Looking up latest Debian standard template..."
pveam update >/dev/null
# the index also carries foreign architectures, only match the host one
ARCH=$(dpkg --print-architecture)
TEMPLATE=$(pveam available --section system | awk -v a="$ARCH" '$2 ~ ("^debian-1[23]-standard_.*_" a "\\.tar") {print $2}' | sort -V | tail -1)
[ -n "$TEMPLATE" ] || { echo "Error: no Debian standard template found via pveam." >&2; exit 1; }
[ -n "$STORAGE" ] || { echo "Error: no storage selected." >&2; exit 1; }
TSTORE=$(pvesm status --content vztmpl | awk 'NR>1 && $3=="active" {print $1; exit}')
[ -n "$TSTORE" ] || { echo "Error: no active template storage found." >&2; exit 1; }
# serialize template downloads and accept a concurrent winner; the list is
# captured first so grep -q cannot close the pipe early under pipefail
have_template() {
    local list
    list=$(pveam list "$TSTORE" 2>/dev/null | awk '{print $1}')
    grep -qx "$TSTORE:vztmpl/$TEMPLATE" <<< "$list"
}
# the lock lives in the root-owned cache dir with a timeout: a lock file in
# the world-writable /var/lock can be held forever by any local user
mkdir -p /var/cache/dietpi-factory
chmod 700 /var/cache/dietpi-factory
exec 8>/var/cache/dietpi-factory/.template.lock
chmod 600 /var/cache/dietpi-factory/.template.lock
flock -w 3600 8 || { echo "Error: timed out waiting for a concurrent template download." >&2; exit 1; }
if ! have_template; then
    pveam download "$TSTORE" "$TEMPLATE" || have_template
fi
exec 8>&-

# dietpi-installer aborts without a preset distro when there is no tty
case $TEMPLATE in
    *debian-13*) DISTRO_TARGET=8 ;;
    *debian-12*) DISTRO_TARGET=7 ;;
    *) echo "Error: cannot map template '$TEMPLATE' to a DietPi distro target." >&2; exit 1 ;;
esac

echo "Creating container ${CTID} (${CT_HOSTNAME})..."
pct create "$CTID" "$TSTORE:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$NET0" \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype debian \
    --onboot 1
CT_CREATED=1

pct start "$CTID"
echo "Waiting for network in the container..."
for _ in $(seq 1 30); do
    pct exec "$CTID" -- ping -c1 -W1 deb.debian.org >/dev/null 2>&1 && break
    sleep 2
done

echo "Converting Debian to DietPi, this takes a while..."
pct exec "$CTID" -- bash -c "apt-get update && apt-get install -y curl ca-certificates"
DIETPI_REF=$(resolve_dietpi_ref) || DIETPI_REF=master
pct exec "$CTID" -- bash -c "I=\$(mktemp) && curl -fsSL 'https://raw.githubusercontent.com/MichaIng/DietPi/${DIETPI_REF}/.build/images/dietpi-installer' -o \"\$I\" && \
    GITOWNER=MichaIng GITBRANCH=${DIETPI_REF} HW_MODEL=75 DISTRO_TARGET=${DISTRO_TARGET} IMAGE_CREATOR=mews_se \
    PREIMAGE_INFO='Debian LXC template' WIFI_REQUIRED=0 bash \"\$I\""

# the installer stamps the pinned SHA as the permanent dietpi-update target,
# which would freeze updates at this commit, point updates back at master
pct exec "$CTID" -- sed -i 's/^DEV_GITBRANCH=.*/DEV_GITBRANCH=master/' /boot/dietpi.txt

# dietpi-software initialises Dropbear as pre-installed although container
# images never ship it, which makes the first run skip the SSH server.
# Fixed upstream in dev (MichaIng/DietPi@4a26253): the installer now seeds
# the state file itself, so only add the line while master still lacks it
pct exec "$CTID" -- bash -c 'grep -q "aSOFTWARE_INSTALL_STATE\[104\]=" /boot/dietpi/.installed 2>/dev/null || echo "aSOFTWARE_INSTALL_STATE[104]=0" >> /boot/dietpi/.installed'

# the conversion removes ifupdown2 from the template and clears the APT lists
echo "Installing ifupdown..."
pct exec "$CTID" -- bash -c "apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown isc-dhcp-client"

echo "Applying profile..."
# the installer ships the stock dietpi.txt, so drop its copies of the profile
# keys and append ours (DietPi reads the first match)
pct push "$CTID" "$TMPD/dietpi.txt" /boot/dietpi-factory.txt
[ ! -r "$TMPD/Automation_Custom_Script.sh" ] || pct push "$CTID" "$TMPD/Automation_Custom_Script.sh" /boot/Automation_Custom_Script.sh
pct exec "$CTID" -- bash -c '
    while IFS= read -r line; do
        [[ $line =~ ^[A-Z][A-Z0-9_]*= ]] || continue
        key=${line%%=*}
        sed -i "/^${key}=/d;/^#${key}=/d" /boot/dietpi.txt
    done < /boot/dietpi-factory.txt
    { echo; grep -E '^[A-Z][A-Z0-9_]*=' /boot/dietpi-factory.txt; } >> /boot/dietpi.txt
    rm /boot/dietpi-factory.txt'

# from here the container is handed over, keep it even if the restart fails
HANDOFF=1
# pct reboot right after the conversion does not take effect, stop/start does
echo "Restarting container..."
pct stop "$CTID"
pct start "$CTID"

echo
echo "Done. Container ${CTID} finishes its DietPi first run setup on its own."
echo "Follow along with: pct console ${CTID}"
