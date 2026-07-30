# MyControl Centre — Proxmox deploy scripts (public)

Public deploy scripts for [MyControl Centre](https://github.com/womail/MycontrolCentre).  
The application source may stay private; these scripts are always fetchable via `curl`.

## Quick start (Proxmox shell, as root)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
```

Advanced wizard:

```bash
mode=advanced bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
```

## Requirements

- Proxmox VE with `pct` and `pveam`
- The **application repo must be cloneable** from the new LXC (public GitHub repo, or set `MCC_GIT_URL` with a token before running — see main project docs)
- Uses [community-scripts](https://community-scripts.org/docs/ct/readme) `build.func`

## Files

| File | Purpose |
|------|---------|
| `proxmox-create-lxc.sh` | CT wizard (community-scripts engine) |
| `proxmox-lxc-deploy.sh` | Standalone deploy (no build.func) |
| `community-scripts/install/mycontrol-centre-install.sh` | In-container install |

## Standalone deploy

```bash
curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-lxc-deploy.sh -o /tmp/mcc-lxc.sh
sudo bash /tmp/mcc-lxc-deploy.sh --source-dir /path/to/MycontrolCentre
```

MIT License — same as MyControl Centre.
