#!/bin/bash
# Runs once at the end of DietPi's automated first boot when copied to /boot.
set -euo pipefail

exec > >(tee -a /var/tmp/dietpi-factory-firstboot.log) 2>&1

# a transient mirror hiccup should not fail the whole first boot
for _ in 1 2 3; do
    if apt-get update && apt-get install -y git; then break; fi
    sleep 10
done

# banner layout: device model, uptime, CPU temp, LAN/WAN IP, disk, RAM,
# load average and kernel - DietPi v10.6 renamed the keys
{
    for k in device_model uptime cpu_temp lan_ip wan_ip disk_usage ram_usage load_average kernel; do
        echo "aENABLED[$k]=1"
    done
    for k in hostname nis_domainname weather custom_commands dietpi_commands motd vpn_status large_hostname credits letsencrypt word_wrap; do
        echo "aENABLED[$k]=0"
    done
} > /boot/dietpi/.dietpi-banner

# fetch hostctl at the first interactive login, then remove the hook; an
# existing ~/hostctl is never touched and a missing git heals later
cat > /etc/profile.d/99-hostctl-firstlogin.sh <<'HOOK'
if [ -n "${PS1:-}" ] && [ "$(id -u)" -ne 0 ] && [ ! -e /var/local/hostctl-firstlogin-done ]; then
    command -v git >/dev/null 2>&1 || sudo apt-get install -y git
    if [ ! -e "$HOME/hostctl" ]; then
        _t=$(mktemp -d)
        if git clone -q https://github.com/mews-se/hostctl.git "$_t/hostctl"; then
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
    elif [ -e "$HOME/hostctl" ]; then
        echo "hostctl: $HOME/hostctl exists but is not the expected clone, move it aside and log in again."
    else
        echo "hostctl: clone failed, will retry at the next login."
    fi
fi
HOOK
