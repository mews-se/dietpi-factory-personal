#!/bin/bash
# Runs once at the end of DietPi's automated first boot
# (AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1 in dietpi.txt).
set -euo pipefail

exec > >(tee -a /var/tmp/dietpi-factory-firstboot.log) 2>&1

apt-get update
apt-get install -y git

# banner layout: device model, uptime, CPU temp, LAN/WAN IP, disk, RAM,
# load average and kernel
for i in $(seq 0 20); do
    case $i in 0|1|2|5|6|7|17|18|20) echo "aENABLED[$i]=1" ;; *) echo "aENABLED[$i]=0" ;; esac
done > /boot/dietpi/.dietpi-banner

# clone and run hostctl at the first interactive login, then remove the hook;
# hostctl needs sudo from a regular user so root logins are skipped
cat > /etc/profile.d/99-hostctl-firstlogin.sh <<'EOF'
if [ -n "${PS1:-}" ] && [ "$(id -u)" -ne 0 ] && [ ! -e /var/local/hostctl-firstlogin-done ]; then
    if [ ! -d "$HOME/hostctl" ]; then
        git clone https://github.com/mews-se/hostctl.git "$HOME/hostctl"
    fi
    if sudo bash "$HOME/hostctl/hostctl.sh"; then
        sudo touch /var/local/hostctl-firstlogin-done
        sudo rm -f /etc/profile.d/99-hostctl-firstlogin.sh
    fi
fi
EOF
