#!/bin/bash
# Bake a dietpi-factory profile into an official DietPi image.
#
#   bake-image.sh <image> [profile dir]
#
# <image> is a URL, a local .img/.img.xz file, or a name/search term matched
# against https://dietpi.com/downloads/images/ - a partial match like "RPi5"
# opens a menu with the variants, no argument lists everything.
# Needs root on Linux. Output lands in build/ as a flashable .img.
set -euo pipefail

BASE_URL=https://dietpi.com/downloads/images
SRC=${1:-}
PROFILE_DIR=${2:-$(dirname "$0")/../config}

[ "$(uname)" = Linux ] || { echo "Error: needs Linux for loop mounts." >&2; exit 1; }
[ "$EUID" -eq 0 ] || { echo "Error: run as root." >&2; exit 1; }
[ -r "$PROFILE_DIR/dietpi.txt" ] || { echo "Error: no dietpi.txt in '$PROFILE_DIR'." >&2; exit 1; }
PROFILE_DIR=$(cd "$PROFILE_DIR" && pwd)
PROFILE_NAME=$(basename "$PROFILE_DIR")

pick_image() {
    local matches
    matches=$(curl -fsSL "$BASE_URL/" | grep -oE 'href="DietPi_[^"]*\.img\.xz"' | cut -d'"' -f2 | sort -u | grep -iF -- "$1" || true)
    [ -n "$matches" ] || { echo "Error: no image matching '$1' at $BASE_URL." >&2; exit 1; }
    if [ "$(wc -l <<< "$matches")" -eq 1 ]; then
        echo "$matches"
    elif [ -t 0 ] && command -v whiptail >/dev/null 2>&1; then
        local opts=()
        while read -r n; do opts+=("$n" ""); done <<< "$matches"
        whiptail --backtitle "dietpi-factory" --title "Image" --menu "Pick an image:" 22 74 14 "${opts[@]}" 3>&1 1>&2 2>&3
    else
        echo "Error: '$1' matches several images, be more specific:" >&2
        echo "$matches" >&2
        exit 1
    fi
}

DIETPI_SIGNING_KEY=C2C4D1DEF7C96C6EDF3937B2536B2A4A2E72D870

# verify the detached signature next to the file against the pinned DietPi
# signing key, in a throwaway keyring so the host one is neither trusted nor touched
verify_signature() {
    command -v gpg >/dev/null 2>&1 || { echo "Error: gpg not found, cannot verify the image signature." >&2; exit 1; }
    local gnupg_tmp status
    gnupg_tmp=$(mktemp -d)
    chmod 700 "$gnupg_tmp"
    curl -fsL https://github.com/MichaIng.gpg | GNUPGHOME=$gnupg_tmp gpg -q --import 2>/dev/null || { rm -rf "$gnupg_tmp"; echo "Error: could not import the DietPi signing key." >&2; exit 1; }
    status=$(GNUPGHOME=$gnupg_tmp gpg --status-fd 1 --verify "$1.asc" "$1" 2>/dev/null) || true
    rm -rf "$gnupg_tmp"
    grep -q "^\[GNUPG:\] VALIDSIG $DIETPI_SIGNING_KEY " <<< "$status" || { echo "Error: GPG signature verification failed for $(basename "$1")." >&2; exit 1; }
}

FILE=
if [[ $SRC == http://* || $SRC == https://* ]]; then
    URL=$SRC
elif [ -n "$SRC" ] && [ -f "$SRC" ]; then
    FILE=$(realpath "$SRC")
else
    URL=$BASE_URL/$(pick_image "$SRC")
fi

mkdir -p build
cd build

OFFICIAL=0
[ -z "$FILE" ] && [[ $URL == "$BASE_URL"/* ]] && OFFICIAL=1

if [ -z "$FILE" ]; then
    FILE=$PWD/$(basename "$URL")
    exec 8>.download.lock
    flock 8
fi

case $FILE in
    *.img.xz) IMG=${FILE%.xz} ;;
    *.img)    IMG=$FILE ;;
    *) echo "Error: expected a .img or .img.xz file." >&2; exit 1 ;;
esac

# official images ship both a checksum and a signature, so both are required
# and the unpacked image is only reused together with the receipt of a passed
# verification; anything older or modified is fetched again. Downloads keep
# their .part name until the checks passed, a failed download cannot be
# mistaken for a verified one on the next run.
if [ "$OFFICIAL" = 1 ]; then
    FRESH=0
    if [ -f "$IMG" ] && [ -f "$IMG.verified" ] && \
        [ "$(sha256sum <"$IMG" | awk '{print $1}') $DIETPI_SIGNING_KEY" = "$(cat "$IMG.verified")" ]; then
        FRESH=1
    fi
    if [ "$FRESH" = 0 ]; then
        echo "Downloading $(basename "$URL")..."
        rm -f "$IMG" "$IMG.verified"
        curl -fL -o "$FILE.part" "$URL"
        curl -fsL -o "$FILE.sha256" "$URL.sha256"
        curl -fsL -o "$FILE.part.asc" "$URL.asc"
        [ "$(sha256sum <"$FILE.part" | awk '{print $1}')" = "$(awk '{print $1}' "$FILE.sha256")" ] || \
            { echo "Error: checksum mismatch for $(basename "$URL")." >&2; exit 1; }
        verify_signature "$FILE.part"
        mv "$FILE.part.asc" "$FILE.asc"
        mv "$FILE.part" "$FILE"
    fi
elif [ -n "${URL:-}" ]; then
    # bind the cached file to its source: a different URL with the same
    # basename, or a file left behind by an older version, is fetched again
    SRC_OK=0
    if [ -f "$FILE" ] && [ -f "$FILE.src" ] && \
        [ "$URL $(sha256sum <"$FILE" | awk '{print $1}')" = "$(cat "$FILE.src")" ]; then
        SRC_OK=1
    fi
    if [ "$SRC_OK" = 0 ]; then
        echo "Downloading $(basename "$URL")..."
        rm -f "$IMG" "$FILE.src"
        curl -fL -o "$FILE.part" "$URL"
        # other URLs are verified with whatever sidecars exist next to them
        curl -fsL -o "$FILE.sha256" "$URL.sha256" 2>/dev/null || rm -f "$FILE.sha256"
        curl -fsL -o "$FILE.part.asc" "$URL.asc" 2>/dev/null || rm -f "$FILE.part.asc"
        if [ ! -f "$FILE.sha256" ] && [ ! -f "$FILE.part.asc" ]; then
            echo "Note: no checksum or signature found next to the URL, continuing unverified."
        fi
        if [ -f "$FILE.sha256" ]; then
            [ "$(sha256sum <"$FILE.part" | awk '{print $1}')" = "$(awk '{print $1}' "$FILE.sha256")" ] || \
                { echo "Error: checksum mismatch for $(basename "$URL")." >&2; exit 1; }
        fi
        if [ -f "$FILE.part.asc" ]; then
            verify_signature "$FILE.part"
            mv "$FILE.part.asc" "$FILE.asc"
        fi
        mv "$FILE.part" "$FILE"
        echo "$URL $(sha256sum <"$FILE" | awk '{print $1}')" > "$FILE.src"
    fi
fi

if [ "$FILE" != "$IMG" ] && [ ! -f "$IMG" ]; then
    xz -dc "$FILE" > "$IMG.part"
    mv "$IMG.part" "$IMG"
fi
if [ "$OFFICIAL" = 1 ] && [ "$FRESH" = 0 ]; then
    echo "$(sha256sum <"$IMG" | awk '{print $1}') $DIETPI_SIGNING_KEY" > "$IMG.verified"
fi
exec 8>&-

OUT=${IMG%.img}-$PROFILE_NAME.img
OUTTMP=$(mktemp "$(dirname "$OUT")/.$(basename "$OUT").XXXXXX")
LOOP='' MOUNTED=0
cleanup() {
    set +e
    [ "$MOUNTED" = 1 ] && umount "$MNT"
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    [ -n "${MNT:-}" ] && rmdir "$MNT" 2>/dev/null
    rm -f "$OUTTMP"
}
trap cleanup EXIT
cp "$IMG" "$OUTTMP"
LOOP=$(losetup -fP --show "$OUTTMP")
MNT=$(mktemp -d)

# dietpi.txt sits on the boot partition on SBC images and in /boot on the
# rootfs on PC images, container images have no partition table at all
# validate the whole profile before doing anything destructive
grep -qE '^[A-Z][A-Z0-9_]*=' "$PROFILE_DIR/dietpi.txt" || { echo "Error: the profile contains no valid KEY=value lines." >&2; exit 1; }
BAD=$(grep -vE '^[A-Z][A-Z0-9_]*=|^#|^[[:space:]]*$' "$PROFILE_DIR/dietpi.txt" || true)
[ -z "$BAD" ] || { printf 'Error: invalid profile lines:\n%s\n' "$BAD" >&2; exit 1; }

shopt -s nullglob
TARGET=
for part in "$LOOP"p* "$LOOP"; do
    mount "$part" "$MNT" 2>/dev/null || continue
    MOUNTED=1
    if [ -f "$MNT/dietpi.txt" ]; then TARGET=$MNT; break; fi
    if [ -f "$MNT/boot/dietpi.txt" ]; then TARGET=$MNT/boot; break; fi
    umount "$MNT"
    MOUNTED=0
done
[ -n "$TARGET" ] || { echo "Error: no dietpi.txt found in the image." >&2; exit 1; }

while IFS= read -r line; do
    [[ $line =~ ^[A-Z][A-Z0-9_]*= ]] || continue
    key=${line%%=*}
    sed -i "/^${key}=/d;/^#${key}=/d" "$TARGET/dietpi.txt"
done < "$PROFILE_DIR/dietpi.txt"
{ echo; grep -E '^[A-Z][A-Z0-9_]*=' "$PROFILE_DIR/dietpi.txt"; } >> "$TARGET/dietpi.txt"
[ ! -r "$PROFILE_DIR/Automation_Custom_Script.sh" ] || cp "$PROFILE_DIR/Automation_Custom_Script.sh" "$TARGET/Automation_Custom_Script.sh"

# make the very first time sync use the profile mirror as well; only doable
# when the rootfs is in reach (PC images), SBC boot partitions are FAT only
mirror=$(sed -n 's/^CONFIG_NTP_MIRROR=//p' "$PROFILE_DIR/dietpi.txt" | head -1)
if [ -n "$mirror" ] && [ -d "$MNT/etc/systemd" ]; then
    mkdir -p "$MNT/etc/systemd/timesyncd.conf.d"
    printf '[Time]\nNTP=%s\n' "$mirror" > "$MNT/etc/systemd/timesyncd.conf.d/dietpi-factory.conf"
fi

umount "$MNT"
MOUNTED=0
losetup -d "$LOOP"
LOOP=''
mv "$OUTTMP" "$OUT"
trap - EXIT
rmdir "$MNT"

echo
echo "Baked $(basename "$OUT") with profile '$PROFILE_NAME'"
echo "Flash with e.g.: dd if=build/$(basename "$OUT") of=/dev/sdX bs=4M conv=fsync status=progress"
