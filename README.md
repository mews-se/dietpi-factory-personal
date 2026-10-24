# dietpi-factory-personal

[![ShellCheck](https://github.com/mews-se/dietpi-factory-personal/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mews-se/dietpi-factory-personal/actions/workflows/shellcheck.yml)
![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnubash&logoColor=white)
![Platform: DietPi / Debian](https://img.shields.io/badge/platform-DietPi%20%2F%20Debian-A81D33.svg?logo=debian&logoColor=white)
![Deploys to: Proxmox](https://img.shields.io/badge/deploys%20to-Proxmox-E57000.svg?logo=proxmox&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

My personal configuration of [dietpi-factory](https://github.com/mews-se/dietpi-factory): hostctl at first login, OpenSSH, my banner layout and other choices baked in. Use at your own risk, the [general version](https://github.com/mews-se/dietpi-factory) is the better starting point for anyone else.

Baked in:

- en_US.UTF-8, Swedish keyboard and Europe/Stockholm as defaults
- OpenSSH as the SSH server
- NTP from the router on my LAN (`CONFIG_NTP_MIRROR`); VMs, conversions and PC images also get it in a timesyncd drop-in so the first sync at boot uses it
- the DietPi survey opted in
- IPv6 off, only in config/dietpi.txt (the fallback of the image baker and the converter)
- SSH password logins for root off when the wizard gets a key
- my banner layout, and [hostctl](https://github.com/mews-se/hostctl) cloned to ~/hostctl and run at the first interactive login of a non-root user; root logins do not trigger it, and the hook removes itself once hostctl has run

The wizard skips the SSH server and custom script questions: it always picks OpenSSH and copies config/Automation_Custom_Script.sh into the profile. Profile arguments and the rest work as in the [general README](https://github.com/mews-se/dietpi-factory#readme).

Profile wizard:

```
./factory.sh
```

Proxmox LXC, run on the host:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/proxmox/create-dietpi-lxc.sh)"
```

Proxmox VM, run on the host:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/proxmox/create-dietpi-vm.sh)"
```

Flashable image, run as root on Linux:

```
sudo scripts/bake-image.sh RPi5 profiles/myprofile
```

Convert a running Debian system, run on the target:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mews-se/dietpi-factory-personal/main/vps/convert-to-dietpi.sh)"
```

MIT license.
