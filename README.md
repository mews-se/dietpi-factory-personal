# dietpi-factory-personal

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![ShellCheck](https://github.com/mews-se/dietpi-factory-personal/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mews-se/dietpi-factory-personal/actions/workflows/shellcheck.yml)
![Platform](https://img.shields.io/badge/platform-DietPi%20%7C%20Proxmox%20%7C%20Debian-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-blue)

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
