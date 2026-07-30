# MyControl Centre — Proxmox deploy scripts (public)

Public deploy scripts for [MyControl Centre](https://github.com/womail/MycontrolCentre).  
The application source may stay private; installs download `artifacts/mycontrol-centre.tar.gz` from this repo.

## Quick start (Proxmox shell, as root)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
```

Advanced wizard:

```bash
mode=advanced bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
```

No GitHub token is required on Proxmox — the install script pulls the public tarball from this repo.

## Requirements

- Proxmox VE with `pct` and `pveam`
- Uses [community-scripts](https://community-scripts.org/docs/ct/readme) `build.func`

## Files

| File | Purpose |
|------|---------|
| `proxmox-create-lxc.sh` | CT wizard (community-scripts engine) |
| `proxmox-lxc-deploy.sh` | Standalone deploy (no build.func) |
| `community-scripts/install/mycontrol-centre-install.sh` | In-container install |
| `artifacts/mycontrol-centre.tar.gz` | Public app source snapshot (updated by CI) |
| `artifacts/source-version.txt` | Git SHA / build time for the tarball |

## Standalone deploy

```bash
curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-lxc-deploy.sh -o /tmp/mcc-lxc.sh
sudo bash /tmp/mcc-lxc-deploy.sh --source-dir /path/to/MycontrolCentre
```

## Publishing the tarball

The main app repo runs `.github/workflows/publish-deploy-tarball.yml` on each push to `main`.  
Add secret `DEPLOY_REPO_TOKEN` (fine-grained PAT, **Contents: Read and write** on this repo).

Manual publish from a checkout:

```bash
bash scripts/publish-deploy-tarball.sh dist/deploy-artifacts
# copy dist/deploy-artifacts/* to artifacts/ in this repo and push
```

MIT License — same as MyControl Centre.
