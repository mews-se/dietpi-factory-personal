#!/bin/bash
# Create a DietPi VM on Proxmox VE from the official qcow2 image. Run on the
# PVE host:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/proxmox/create-dietpi-vm.sh)"
#
# The profile is injected into the disk image before the first boot, so the
# VM sets itself up unattended. Pass a factory.sh profile directory as first
# argument (or PROFILE_DIR) to use it instead of the embedded defaults.
# ASSUME_DEFAULTS=1 skips all dialogs.
set -euo pipefail

BASE_URL=https://dietpi.com/downloads/images
PROFILE_DIR=${PROFILE_DIR:-${1:-}}
ASSUME_DEFAULTS=${ASSUME_DEFAULTS:-0}

command -v qm >/dev/null 2>&1 || { echo "Error: must be run on a Proxmox VE host." >&2; exit 1; }
[ "$ASSUME_DEFAULTS" = 1 ] || command -v whiptail >/dev/null 2>&1 || { echo "Error: whiptail not found." >&2; exit 1; }
if [ -n "$PROFILE_DIR" ] && [ ! -r "$PROFILE_DIR/dietpi.txt" ]; then
    echo "Error: no readable dietpi.txt in profile dir '$PROFILE_DIR'." >&2
    exit 1
fi

ask() {
    if [ "$ASSUME_DEFAULTS" = 1 ]; then echo "$3"; return; fi
    whiptail --backtitle "dietpi-factory" --title "$1" --inputbox "$2" 10 60 "$3" 3>&1 1>&2 2>&3
}

VMID=$(ask "VM ID" "VM ID:" "$(pvesh get /cluster/nextid)")
VM_NAME=$(ask "Name" "VM name:" "dietpi")
CORES=$(ask "CPU" "Number of cores:" "2")
RAM=$(ask "Memory" "RAM in MiB:" "2048")
DISK=$(ask "Disk" "Disk size in GiB (image is grown to this):" "8")
BRIDGE=$(ask "Network" "Bridge:" "vmbr0")
DISTRO=$(ask "Distro" "Debian release (Bookworm/Trixie/Forky):" "Trixie")
FIRMWARE=$(ask "Firmware" "Firmware (bios/uefi):" "bios")

if [ "$ASSUME_DEFAULTS" = 1 ]; then
    # the storage with the most free space
    STORAGE=$(pvesm status --content images | awk 'NR>1' | sort -k6 -n | tail -1 | awk '{print $1}')
else
    STORAGE_OPTS=()
    while read -r name; do STORAGE_OPTS+=("$name" ""); done < <(pvesm status --content images | awk 'NR>1 {print $1}')
    STORAGE=$(whiptail --backtitle "dietpi-factory" --title "Storage" \
        --menu "Storage for the VM disk:" 16 60 8 "${STORAGE_OPTS[@]}" 3>&1 1>&2 2>&3)
fi

case $FIRMWARE in
    [Uu]*) IMAGE=DietPi_Proxmox-UEFI-x86_64-${DISTRO}.qcow2.xz; UEFI=1 ;;
    *)     IMAGE=DietPi_Proxmox-x86_64-${DISTRO}.qcow2.xz; UEFI=0 ;;
esac
cd /var/tmp
if [ ! -f "${IMAGE%.xz}" ]; then
    echo "Downloading ${IMAGE}..."
    curl -fLO "$BASE_URL/$IMAGE"
    if curl -fsLO "$BASE_URL/$IMAGE.sha256" 2>/dev/null; then
        sha256sum -c "$IMAGE.sha256"
    fi
    xz -dk "$IMAGE"
fi
QCOW2=/var/tmp/${IMAGE%.xz}

##### Inject the profile into the image before first boot #####
TMPD=$(mktemp -d)
MNT=$TMPD/mnt
mkdir -p "$MNT"

if [ -n "$PROFILE_DIR" ]; then
    cp "$PROFILE_DIR/dietpi.txt" "$TMPD/dietpi.txt"
    [ ! -r "$PROFILE_DIR/Automation_Custom_Script.sh" ] || cp "$PROFILE_DIR/Automation_Custom_Script.sh" "$TMPD/Automation_Custom_Script.sh"
else
    sed "s/__HOSTNAME__/${VM_NAME}/" > "$TMPD/dietpi.txt" <<'EOF'
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

modprobe nbd max_part=8
NBD=
for d in /sys/class/block/nbd[0-9]*; do
    [ -s "$d/pid" ] || { NBD=/dev/$(basename "$d"); break; }
done
[ -n "$NBD" ] || { echo "Error: no free nbd device." >&2; exit 1; }

cleanup() {
    mountpoint -q "$MNT" && umount "$MNT"
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
    rm -rf "$TMPD"
}
trap cleanup EXIT

qemu-nbd --connect="$NBD" "$QCOW2"
partprobe "$NBD" 2>/dev/null
sleep 1

shopt -s nullglob
TARGET=
for part in "$NBD"p* "$NBD"; do
    mount "$part" "$MNT" 2>/dev/null || continue
    if [ -f "$MNT/dietpi.txt" ]; then TARGET=$MNT; break; fi
    if [ -f "$MNT/boot/dietpi.txt" ]; then TARGET=$MNT/boot; break; fi
    umount "$MNT"
done
[ -n "$TARGET" ] || { echo "Error: no dietpi.txt found in the image." >&2; exit 1; }

while IFS= read -r line; do
    case $line in [A-Z]*=*) ;; *) continue ;; esac
    key=${line%%=*}
    sed -i "/^${key}=/d;/^#${key}=/d" "$TARGET/dietpi.txt"
done < "$TMPD/dietpi.txt"
{ echo; grep "^[A-Z0-9_]*=" "$TMPD/dietpi.txt"; } >> "$TARGET/dietpi.txt"
[ ! -r "$TMPD/Automation_Custom_Script.sh" ] || cp "$TMPD/Automation_Custom_Script.sh" "$TARGET/Automation_Custom_Script.sh"

# make the very first time sync use the profile mirror as well, the boot
# sequence syncs before the mirror in dietpi.txt is applied
mirror=$(sed -n 's/^CONFIG_NTP_MIRROR=//p' "$TMPD/dietpi.txt" | head -1)
if [ -n "$mirror" ] && [ -d "$MNT/etc/systemd" ]; then
    mkdir -p "$MNT/etc/systemd/timesyncd.conf.d"
    printf '[Time]\nNTP=%s\n' "$mirror" > "$MNT/etc/systemd/timesyncd.conf.d/dietpi-factory.conf"
fi

umount "$MNT"
qemu-nbd --disconnect "$NBD" >/dev/null
trap - EXIT
rm -rf "$TMPD"

##### Create and start the VM #####
echo "Creating VM ${VMID} (${VM_NAME})..."
UEFI_ARGS=()
# keys pre-enrolled, the images ship the signed Debian boot chain
[ "$UEFI" = 0 ] || UEFI_ARGS=(--bios ovmf --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=1")
qm create "$VMID" \
    --name "$VM_NAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-pci \
    --scsi0 "${STORAGE}:0,import-from=${QCOW2},discard=on,ssd=1" \
    --boot order=scsi0 \
    --ostype l26 \
    --onboot 1 \
    "${UEFI_ARGS[@]}" \
    --description "<p align='center'><img src='https://dietpi.com/images/dietpi-logo_128x128.png' width='40'><br><strong>DietPi</strong><br><a href='https://dietpi.com/docs/'>Docs</a> - <a href='https://github.com/mews-se/dietpi-factory-personal'>dietpi-factory-personal</a></p>"

# the image is 8 GiB virtual, only grow when a larger disk was requested
CUR_BYTES=$(qemu-img info --output=json "$QCOW2" | sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p')
if [ "$(( DISK * 1024*1024*1024 ))" -gt "${CUR_BYTES:-0}" ]; then
    qm disk resize "$VMID" scsi0 "${DISK}G"
fi
qm start "$VMID"

echo
echo "Done. VM ${VMID} finishes its DietPi first boot setup on its own."
echo "It gets a fresh DHCP lease, look for hostname '${VM_NAME}' in your DNS."
