# scripts

Standalone server-provisioning scripts for Ubuntu (20.04 / 22.04 / 24.04). Each script is self-contained and can be run directly with a single command, no need to clone the whole repo.

Shared helper functions live in [utils.sh](utils.sh) and are fetched automatically by every script.

## General usage

- All commands below install `curl` first (required to fetch the script itself), then run the script directly from GitHub.
- Pass `-y` to auto-approve all confirmations, or `-n` to auto-decline all of them.
- Every script is safe to re-run (it detects a previous installation and offers to reset it from scratch).

## Scripts

### Install MongoDB

Installs from the official `repo.mongodb.org` repo, or via Docker.

```bash
sudo apt-get update -y && sudo apt-get install -y curl && bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/install_mongodb.sh)
```

**Args:**
- `-y` / `-n` — auto-approve / auto-decline confirmations.
- `native` / `docker` — install method (skips the interactive question if passed).

### Install Nginx

Installs from the official `nginx.org` repo, or via Docker Compose. Optional Cloudflare integration (origin cert required, or a self-signed cert is generated automatically).

```bash
sudo apt-get update -y && sudo apt-get install -y curl && bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/install_nginx.sh)
```

**Args:**
- `-y` / `-n` — auto-approve / auto-decline confirmations.
- `-d example.com` — domain name (skips the interactive prompt if passed).
- `native` / `docker` — install method.
- `cloudflare` / `no-cloudflare` — whether to run behind Cloudflare.

### Enable UFW firewall

Enables UFW while keeping SSH open, and checks for affected services/old rules before enabling.

```bash
sudo apt-get update -y && sudo apt-get install -y curl && bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/setup_ufw.sh)
```

**Args:**
- `-y` / `-n` — auto-approve / auto-decline confirmations.

### Run multiple scripts together

Lists every script available in this repo (fetched live from GitHub) and lets you pick more than one to run together, in the exact order you enter them.

```bash
sudo apt-get update -y && sudo apt-get install -y curl && bash <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/run_scripts.sh)
```

**Args:**
- `-y` / `-n` — auto-approve / auto-decline confirmations (forwarded to every script it runs).

## Helpers (utils.sh)

### Interactive function menu

Lists every function defined in [utils.sh](utils.sh), numbered. Pick one by number, optionally pass it arguments, and repeat until you exit (enter `0` or press `Ctrl+C`).

```bash
sudo apt-get update -y && sudo apt-get install -y curl && source <(curl -fsSL https://raw.githubusercontent.com/eeeob/scripts/main/utils.sh) && _run_utils_menu
```

**Args:** none — fully interactive.
