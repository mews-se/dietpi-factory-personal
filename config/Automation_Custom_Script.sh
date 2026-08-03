#!/bin/bash
# Runs once at the end of DietPi's automated first boot
# (AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1 in dietpi.txt).
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
