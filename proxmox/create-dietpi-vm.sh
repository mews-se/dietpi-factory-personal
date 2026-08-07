#!/bin/bash
# Create a DietPi VM on Proxmox VE from the official qcow2 image. Run on the
# PVE host:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/proxmox/create-dietpi-vm.sh)"
#
# The profile is injected into a working copy of the disk image before the
# first boot, so the VM sets itself up unattended. Pass a factory.sh profile
# directory as first argument (or PROFILE_DIR) to use it instead of the
# embedded defaults. ASSUME_DEFAULTS=1 skips all dialogs.
set -euo pipefail

BASE_URL=https://dietpi.com/downloads/images
CACHE=/var/cache/dietpi-factory
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

require_uint() {
    case $2 in ''|*[!0-9]*|0[0-9]*) echo "Error: $1 '$2' is not a plain number." >&2; exit 1 ;; esac
    [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || { echo "Error: $1 must be between $3 and $4." >&2; exit 1; }
}

DIETPI_SIGNING_KEY=C2C4D1DEF7C96C6EDF3937B2536B2A4A2E72D870

# verify the detached signature next to the file against the pinned DietPi
# signing key, in a throwaway keyring so the host one is neither trusted nor touched
verify_signature() {
    command -v gpg >/dev/null 2>&1 || { echo "Error: gpg not found, cannot verify the image signature." >&2; exit 1; }
    local gnupg_tmp status
    gnupg_tmp=$(mktemp -d)
    chmod 700 "$gnupg_tmp"
    # a plain keyring file needs neither an import nor the gpg-agent that
    # minimal systems lack
    curl -fsL https://github.com/MichaIng.gpg | GNUPGHOME=$gnupg_tmp gpg --dearmor > "$gnupg_tmp/key.gpg" 2>/dev/null || { rm -rf "$gnupg_tmp"; echo "Error: could not fetch the DietPi signing key." >&2; exit 1; }
    status=$(GNUPGHOME=$gnupg_tmp gpg --status-fd 1 --no-default-keyring --keyring "$gnupg_tmp/key.gpg" --verify "$1.asc" "$1" 2>/dev/null) || true
    rm -rf "$gnupg_tmp"
    grep -q "^\[GNUPG:\] VALIDSIG $DIETPI_SIGNING_KEY " <<< "$status" || { echo "Error: GPG signature verification failed for $(basename "$1")." >&2; exit 1; }
}

VMID=$(ask "VM ID" "VM ID:" "$(pvesh get /cluster/nextid)")
VM_NAME=$(ask "Name" "VM name:" "dietpi")
CORES=$(ask "CPU" "Number of cores:" "2")
RAM=$(ask "Memory" "RAM in MiB:" "2048")
DISK=$(ask "Disk" "Disk size in GiB (image is grown to this):" "8")
BRIDGE=$(ask "Network" "Bridge:" "vmbr0")
DISTRO=$(ask "Distro" "Debian release (Bookworm/Trixie/Forky):" "Trixie")
FIRMWARE=$(ask "Firmware" "Firmware (bios/uefi):" "bios")

require_uint "VM ID" "$VMID" 100 999999999
require_uint "cores" "$CORES" 1 256
require_uint "RAM" "$RAM" 128 4194304
require_uint "disk size" "$DISK" 1 65536
[[ $VM_NAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] && [ ${#VM_NAME} -le 63 ] || { echo "Error: invalid VM name '$VM_NAME'." >&2; exit 1; }

# fail early on a taken ID, qm create remains the authoritative check;
# capture first so grep -q cannot close the pipe early under pipefail
CLUSTER_GUESTS=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || true)
if grep -Eq "\"vmid\":[[:space:]]*${VMID}[,}]" <<< "$CLUSTER_GUESTS"; then
    echo "Error: ID $VMID is already in use." >&2
    exit 1
fi

if [ "$ASSUME_DEFAULTS" = 1 ]; then
    # the active storage with the most free space
    STORAGE=$(pvesm status --content images | awk 'NR>1 && $3=="active"' | sort -k6 -n | tail -1 | awk '{print $1}')
else
    STORAGE_OPTS=()
    while read -r name; do STORAGE_OPTS+=("$name" ""); done < <(pvesm status --content images | awk 'NR>1 && $3=="active" {print $1}')
    [ ${#STORAGE_OPTS[@]} -gt 0 ] || { echo "Error: no active storage with VM image support found." >&2; exit 1; }
    STORAGE=$(whiptail --backtitle "dietpi-factory" --title "Storage" \
        --menu "Storage for the VM disk:" 16 60 8 "${STORAGE_OPTS[@]}" 3>&1 1>&2 2>&3)
fi
[ -n "$STORAGE" ] || { echo "Error: no storage selected." >&2; exit 1; }

case $FIRMWARE in
    [Uu]*) IMAGE=DietPi_Proxmox-UEFI-x86_64-${DISTRO}.qcow2.xz; UEFI=1 ;;
    *)     IMAGE=DietPi_Proxmox-x86_64-${DISTRO}.qcow2.xz; UEFI=0 ;;
esac

##### Base image cache, checksum gated and never modified #####
mkdir -p "$CACHE"
QCOW2=$CACHE/${IMAGE%.xz}
exec 8>"$CACHE/.download.lock"
flock 8
# a cache entry is only trusted with the receipt of a passed verification,
# entries from before the signature gate or modified since are rebuilt
CACHED=0
if [ -f "$QCOW2" ] && [ -f "$QCOW2.verified" ] && \
    [ "$(sha256sum <"$QCOW2" | awk '{print $1}') $DIETPI_SIGNING_KEY" = "$(cat "$QCOW2.verified")" ]; then
    CACHED=1
fi
if [ "$CACHED" = 0 ]; then
    echo "Downloading ${IMAGE}..."
    rm -f "$QCOW2" "$QCOW2.verified" "$CACHE/$IMAGE" "$CACHE/$IMAGE.sha256" "$CACHE/$IMAGE.asc"
    curl -fL -o "$CACHE/$IMAGE" "$BASE_URL/$IMAGE"
    curl -fsL -o "$CACHE/$IMAGE.sha256" "$BASE_URL/$IMAGE.sha256"
    curl -fsL -o "$CACHE/$IMAGE.asc" "$BASE_URL/$IMAGE.asc"
    ( cd "$CACHE" && sha256sum -c "$IMAGE.sha256" )
    verify_signature "$CACHE/$IMAGE"
    xz -dc "$CACHE/$IMAGE" > "$QCOW2.part"
    mv "$QCOW2.part" "$QCOW2"
    echo "$(sha256sum <"$QCOW2" | awk '{print $1}') $DIETPI_SIGNING_KEY" > "$QCOW2.verified"
fi
exec 8>&-

##### Inject the profile into a working copy of the image #####
TMPD=$(mktemp -d)
MNT=$TMPD/mnt
mkdir -p "$MNT"
# working copy on the same filesystem as the cache, reflinked where supported
WORK=$CACHE/.work.$$.qcow2
MOUNTED=0 NBD_CONNECTED=0 VM_CREATED=0 HANDOFF=0

cleanup() {
    set +e
    [ "$MOUNTED" = 1 ] && umount "$MNT"
    [ "$NBD_CONNECTED" = 1 ] && qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
    if [ "$VM_CREATED" = 1 ] && [ "$HANDOFF" = 0 ]; then
        for _ in 1 2 3; do
            qm destroy "$VMID" --purge >/dev/null 2>&1
            qm config "$VMID" >/dev/null 2>&1 || break
            sleep 3
        done
        if qm config "$VMID" >/dev/null 2>&1; then
            echo "Warning: VM $VMID could not be removed, inspect with: qm config $VMID" >&2
        fi
    fi
    rm -f "$WORK"
    rm -rf "$TMPD"
}
trap cleanup EXIT

cp --reflink=auto --sparse=always "$QCOW2" "$WORK"

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
    echo "AUTO_SETUP_NET_HOSTNAME=$VM_NAME" >> "$TMPD/dietpi.txt"
    cat > "$TMPD/Automation_Custom_Script.sh" <<'CSEOF'
#!/bin/bash
set -euo pipefail
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
            git -C "$_t/hostctl" checkout -q e855a90c76d88b7b98746dae797d091ebe9518cb &&
            [ "$(git -C "$_t/hostctl" rev-parse HEAD)" = e855a90c76d88b7b98746dae797d091ebe9518cb ]; then
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

# validate the whole profile before touching anything
mapfile -t PROFILE_LINES < <(grep -E '^[A-Z][A-Z0-9_]*=' "$TMPD/dietpi.txt" || true)
[ ${#PROFILE_LINES[@]} -gt 0 ] || { echo "Error: the profile contains no valid KEY=value lines." >&2; exit 1; }
BAD=$(grep -vE '^[A-Z][A-Z0-9_]*=|^#|^[[:space:]]*$' "$TMPD/dietpi.txt" || true)
[ -z "$BAD" ] || { printf 'Error: invalid profile lines:\n%s\n' "$BAD" >&2; exit 1; }

# serialize nbd allocation between concurrent runs
exec 9>/var/lock/dietpi-factory-nbd
flock 9
modprobe nbd max_part=8
NBD=
for d in /sys/class/block/nbd[0-9]*; do
    [ -s "$d/pid" ] || { NBD=/dev/$(basename "$d"); break; }
done
[ -n "$NBD" ] || { echo "Error: no free nbd device." >&2; exit 1; }

qemu-nbd --connect="$NBD" "$WORK"
NBD_CONNECTED=1
partprobe "$NBD" 2>/dev/null
sleep 1

shopt -s nullglob
TARGET=
for part in "$NBD"p* "$NBD"; do
    mount "$part" "$MNT" 2>/dev/null || continue
    MOUNTED=1
    if [ -f "$MNT/dietpi.txt" ]; then TARGET=$MNT; break; fi
    if [ -f "$MNT/boot/dietpi.txt" ]; then TARGET=$MNT/boot; break; fi
    umount "$MNT"
    MOUNTED=0
done
[ -n "$TARGET" ] || { echo "Error: no dietpi.txt found in the image." >&2; exit 1; }

for line in "${PROFILE_LINES[@]}"; do
    key=${line%%=*}
    sed -i "/^${key}=/d;/^#${key}=/d" "$TARGET/dietpi.txt"
done
{ echo; printf '%s\n' "${PROFILE_LINES[@]}"; } >> "$TARGET/dietpi.txt"
[ ! -r "$TMPD/Automation_Custom_Script.sh" ] || cp "$TMPD/Automation_Custom_Script.sh" "$TARGET/Automation_Custom_Script.sh"

# make the very first time sync use the profile mirror as well, the boot
# sequence syncs before the mirror in dietpi.txt is applied
mirror=$(sed -n 's/^CONFIG_NTP_MIRROR=//p' "$TMPD/dietpi.txt" | head -1)
if [ -n "$mirror" ] && [ -d "$MNT/etc/systemd" ]; then
    mkdir -p "$MNT/etc/systemd/timesyncd.conf.d"
    printf '[Time]\nNTP=%s\n' "$mirror" > "$MNT/etc/systemd/timesyncd.conf.d/dietpi-factory.conf"
fi

umount "$MNT"
MOUNTED=0
qemu-nbd --disconnect "$NBD" >/dev/null
NBD_CONNECTED=0
exec 9>&-

##### Create and start the VM #####
echo "Creating VM ${VMID} (${VM_NAME})..."
# create the bare config first and attach storage afterwards: when the create
# fails, typically on a taken ID, nothing of ours exists yet and nothing is
# removed. The cleanup trap only ever destroys a VM this run created itself.
if ! qm create "$VMID" \
    --name "$VM_NAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-pci \
    --boot order=scsi0 \
    --ostype l26 \
    --onboot 1 \
    --description "<p align='center'><img src='https://dietpi.com/images/dietpi-logo_128x128.png' width='40'><br><strong>DietPi</strong><br><a href='https://dietpi.com/docs/'>Docs</a> - <a href='https://github.com/mews-se/dietpi-factory-personal'>dietpi-factory-personal</a></p>"
then
    echo "Error: qm create failed, is ID $VMID already in use?" >&2
    exit 1
fi
VM_CREATED=1
# keys pre-enrolled, the images ship the signed Debian boot chain
[ "$UEFI" = 0 ] || qm set "$VMID" --machine q35 --bios ovmf --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=1"
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${WORK},discard=on,ssd=1"

# the image is 8 GiB virtual, only grow when a larger disk was requested;
# newer qemu-img repeats virtual-size for child nodes in the json output,
# the human readable line is the one that stays unique
CUR_BYTES=$(qemu-img info "$QCOW2" | sed -n 's/^virtual size:.*(\([0-9]*\) bytes).*/\1/p')
if [ "$(( DISK * 1024*1024*1024 ))" -gt "${CUR_BYTES:-0}" ]; then
    qm disk resize "$VMID" scsi0 "${DISK}G"
fi

# from here the VM is handed over, keep it even if the start fails
HANDOFF=1
if ! qm start "$VMID"; then
    echo "The VM was created but failed to start. Inspect with: qm config $VMID" >&2
    exit 1
fi

echo
echo "Done. VM ${VMID} finishes its DietPi first boot setup on its own."
echo "It gets a fresh DHCP lease, look for hostname '${VM_NAME}' in your DNS."
