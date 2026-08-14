# dietpi-factory-personal

[![ShellCheck](https://github.com/mews-se/dietpi-factory-personal/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mews-se/dietpi-factory-personal/actions/workflows/shellcheck.yml)
![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnubash&logoColor=white)
![Platform: DietPi / Debian](https://img.shields.io/badge/platform-DietPi%20%2F%20Debian-A81D33.svg?logo=debian&logoColor=white)
![Deploys to: Proxmox](https://img.shields.io/badge/deploys%20to-Proxmox-E57000.svg?logo=proxmox&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

My personal configuration of [dietpi-factory](https://github.com/mews-se/dietpi-factory): hostctl at first login, OpenSSH, my banner layout and other choices baked in. Use at your own risk, the [general version](https://github.com/mews-se/dietpi-factory) is the better starting point for anyone else.

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
