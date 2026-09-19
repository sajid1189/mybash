# hetzner-podman-bootstrap.sh — What It Does

This script turns a brand-new Hetzner Cloud server (Debian 12 or Ubuntu 22.04+) into a secure host for running apps in rootless Podman containers. Containers are managed by systemd, so there's no docker-compose to deal with.

This server doesn't handle HTTPS or run a reverse proxy. A separate nginx VPS does that and forwards traffic to the containers here. The firewall only lets that nginx VPS reach the app ports.

You run it once, as root, right after the server first boots. It's safe to run again: each step checks what's already done before changing anything.

## How to run it

```bash
scp hetzner-podman-bootstrap.sh root@<ip>:~
ssh root@<ip>
chmod +x hetzner-podman-bootstrap.sh
NEW_USER=deploy SSH_PORT=22 PROXY_IP=<nginx-vps-ip> ./hetzner-podman-bootstrap.sh
```

## Settings you can change

Set these as environment variables before the command. Anything you leave out uses its default.

| Setting | What it controls | Default |
|---|---|---|
| `NEW_USER` | Name of the non-root user to create | `deploy` |
| `SSH_PORT` | Port SSH listens on | `22` |
| `TIMEZONE` | Server timezone | `UTC` |
| `SWAP_SIZE_MB` | Swapfile size in MB (`0` = no swap) | Twice the RAM, capped at 4096 |
| `ADMIN_SSH_KEY` | Public SSH key to give the new user | Copies root's existing keys |
| `PROXY_IP` | IP of your nginx VPS, which is allowed to reach the app ports | None (app ports stay closed) |
| `APP_PORTS` | Range of host ports your containers publish | `8000:8999` |

## The steps

### Safety checks (before anything changes)
- The script stops immediately if any command fails or a variable is missing, so it never carries on half-configured.
- It confirms you're root and that the system uses `apt` (Debian/Ubuntu). If not, it exits.

### 1. Update the system and install tools
Updates all packages, then installs the basics: `curl`, `wget`, `git`, `jq`, a firewall (`ufw`), brute-force protection (`fail2ban`), automatic updates, time sync (`chrony`), and the helpers rootless containers need.

### 2. Set the timezone
Sets the server clock to `TIMEZONE` (UTC by default).

### 3. Create a swapfile
Small servers can run out of memory, and Linux then kills processes, possibly your containers. A swapfile gives the server some overflow space on disk.
- The size is `SWAP_SIZE_MB`, or twice the RAM (max 4 GB) if you didn't set it.
- It's skipped if you set `0` or if a swapfile already exists.
- It's made permanent across reboots.
- The kernel is told to prefer real RAM and use swap only as a safety net.

### 4. Create the deploy user
- Creates `NEW_USER` with no password and adds it to the `sudo` group.
- Copies your SSH key to the new user (either `ADMIN_SSH_KEY` or root's existing keys), removing duplicates.
- Gives the user passwordless `sudo`, which makes automated deploys easier.
- Warns you if no key could be found, because you'd be locked out.

### 5. Lock down SSH
- Moves SSH to `SSH_PORT`.
- Turns off root login and password login, so only SSH keys work.
- Limits login attempts and how long a login can take.
- Tests the config before reloading, so a typo can't break SSH.
- It skips the password-disable part if the new user has no key, to avoid locking you out.

### 6. Set up the firewall
Resets the firewall, blocks all incoming traffic by default, and allows only:
- Your SSH port, from anywhere
- The app ports (`APP_PORTS`), **only from `PROXY_IP`**

Ports 80 and 443 are not opened, because HTTPS is handled by the nginx VPS. If you don't set `PROXY_IP`, the script warns you and leaves the app ports closed, so nginx can't reach the containers until you add the rule.

### 7. Turn on fail2ban
Watches SSH logins and temporarily bans an IP for 1 hour after 5 failed attempts within 10 minutes.

### 8. Turn on automatic security updates
The server installs security patches by itself and cleans up old package files weekly.

### 9. Install Podman (rootless)
- Installs Podman.
- Makes sure the deploy user has the ID ranges containers need.
- Enables "linger", so the user's containers keep running after you log out of SSH.

### 10. Set up the container layout
In the deploy user's home folder, the script creates:
- **A Quadlet folder** (`~/.config/containers/systemd/`), where each app's `.container` file goes.
- **An `apps` folder** for app files.
- **A sample app file** (`example-app.container.sample`) to copy when deploying a real app. It publishes host port 8080, inside the default `APP_PORTS` range. It's disabled by default.
- **A weekly cleanup job** that removes unused container images and data so the disk doesn't fill up.

It then starts the cleanup timer as the deploy user.

### 11. Cap log size
Limits the system journal to 500 MB so chatty containers can't fill the disk with logs.

## After the script finishes

It prints a summary and these next steps:

1. **Don't close your root session yet.** From another terminal, check you can log in as the new user: `ssh -p <SSH_PORT> <NEW_USER>@<server-ip>`.
2. **Deploy an app** by writing a `.container` file in `~/.config/containers/systemd/` (use the sample as a template). Its `PublishPort` must be inside `APP_PORTS`. Then run:
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now <name>.service
   ```
3. **Point nginx at it.** On the nginx VPS, add a `proxy_pass http://<this-vps-ip>:<host-port>;` for each app. HTTPS stays on the nginx VPS.

From here on, run `systemctl` and `podman` commands as the deploy user, not root.
