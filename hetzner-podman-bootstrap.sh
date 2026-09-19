#!/usr/bin/env bash
#
# hetzner-podman-bootstrap.sh
#
# Bootstraps a fresh Hetzner Cloud VPS (Debian 12 / Ubuntu 22.04+) into a
# host for rootless Podman-containerized web apps, managed via systemd
# Quadlet units (no docker-compose / podman-compose needed).
#
# Usage (as root, right after first boot):
#   curl -fsSL https://.../hetzner-podman-bootstrap.sh -o bootstrap.sh
#   chmod +x bootstrap.sh
#   NEW_USER=deploy SSH_PORT=22 ./bootstrap.sh
#
# Re-running is safe: every step checks current state before changing it.
#
# Configuration (override via environment variables):
#   NEW_USER          Non-root deploy user to create        (default: deploy)
#   SSH_PORT           SSH port sshd will listen on           (default: 22)
#   TIMEZONE           System timezone                        (default: UTC)
#   SWAP_SIZE_MB        Swapfile size in MB, 0 disables it     (default: auto, min(2*RAM,4096))
#   ADMIN_SSH_KEY       Public key to authorize for NEW_USER   (default: copy root's authorized_keys)
#   UNPRIVILEGED_PORT_START  Lowest port rootless podman may bind (default: 80)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
NEW_USER="${NEW_USER:-deploy}"
SSH_PORT="${SSH_PORT:-22}"
TIMEZONE="${TIMEZONE:-UTC}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-}"
ADMIN_SSH_KEY="${ADMIN_SSH_KEY:-}"
UNPRIVILEGED_PORT_START="${UNPRIVILEGED_PORT_START:-80}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { echo; c_green "==> $*"; }
warn() { c_yellow "WARN: $*"; }
die() { c_red "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run this script as root (fresh Hetzner image logs you in as root)."

if ! command -v apt-get >/dev/null 2>&1; then
  die "this script targets Debian/Ubuntu (apt-get not found)."
fi

. /etc/os-release
step "Detected ${PRETTY_NAME}"

# ---------------------------------------------------------------------------
# 1. System update + base packages
# ---------------------------------------------------------------------------
step "Updating base system"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get -y -q upgrade
apt-get install -y -q \
  curl wget gnupg2 ca-certificates lsb-release \
  ufw fail2ban unattended-upgrades apt-listchanges \
  uidmap slirp4netns fuse-overlayfs \
  chrony jq git

# ---------------------------------------------------------------------------
# 2. Timezone
# ---------------------------------------------------------------------------
step "Setting timezone to ${TIMEZONE}"
timedatectl set-timezone "${TIMEZONE}"

# ---------------------------------------------------------------------------
# 3. Swap (Hetzner's cheaper plans are RAM-constrained; a swapfile keeps
#    the OOM killer from taking out containers under a memory spike)
# ---------------------------------------------------------------------------
step "Configuring swap"
if [ -z "${SWAP_SIZE_MB}" ]; then
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  SWAP_SIZE_MB=$(( mem_mb * 2 ))
  [ "${SWAP_SIZE_MB}" -gt 4096 ] && SWAP_SIZE_MB=4096
fi

if [ "${SWAP_SIZE_MB}" -eq 0 ]; then
  warn "SWAP_SIZE_MB=0, skipping swap setup"
elif swapon --show=NAME --noheadings | grep -q '/swapfile'; then
  echo "swapfile already active, skipping"
else
  fallocate -l "${SWAP_SIZE_MB}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}"
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # low swappiness: prefer RAM, use swap only as a safety net for containers
  cat >/etc/sysctl.d/99-swap.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
  sysctl --system >/dev/null
fi

# ---------------------------------------------------------------------------
# 4. Deploy user
# ---------------------------------------------------------------------------
step "Creating deploy user '${NEW_USER}'"
if id "${NEW_USER}" >/dev/null 2>&1; then
  echo "user ${NEW_USER} already exists"
else
  adduser --disabled-password --gecos "" "${NEW_USER}"
  usermod -aG sudo "${NEW_USER}"
fi

install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "/home/${NEW_USER}/.ssh"
AUTH_KEYS="/home/${NEW_USER}/.ssh/authorized_keys"

if [ -n "${ADMIN_SSH_KEY}" ]; then
  echo "${ADMIN_SSH_KEY}" >> "${AUTH_KEYS}"
elif [ -s /root/.ssh/authorized_keys ]; then
  cat /root/.ssh/authorized_keys >> "${AUTH_KEYS}"
else
  warn "no ADMIN_SSH_KEY provided and /root/.ssh/authorized_keys is empty."
  warn "you MUST add a key to ${AUTH_KEYS} before disabling password auth, or you will lock yourself out."
fi
sort -u -o "${AUTH_KEYS}" "${AUTH_KEYS}" 2>/dev/null || true
chmod 600 "${AUTH_KEYS}"
chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"

# passwordless sudo for the deploy user simplifies unattended app deploys;
# drop this file if you want sudo to prompt for a password instead.
echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${NEW_USER}"
chmod 440 "/etc/sudoers.d/90-${NEW_USER}"

# ---------------------------------------------------------------------------
# 5. SSH hardening
# ---------------------------------------------------------------------------
step "Hardening sshd (port ${SSH_PORT}, key-only, no root login)"
if [ ! -s "${AUTH_KEYS}" ]; then
  warn "skipping PasswordAuthentication=no because ${AUTH_KEYS} is empty (would lock you out)."
else
  SSHD_DROPIN=/etc/ssh/sshd_config.d/99-hardening.conf
  cat > "${SSHD_DROPIN}" <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding yes
MaxAuthTries 4
LoginGraceTime 20
EOF
  sshd -t -f "${SSHD_DROPIN}" 2>/dev/null || sshd -t # validate merged config
  systemctl reload ssh || systemctl reload sshd
fi

# ---------------------------------------------------------------------------
# 6. Firewall (UFW)
# ---------------------------------------------------------------------------
step "Configuring UFW firewall"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# ---------------------------------------------------------------------------
# 7. fail2ban for sshd
# ---------------------------------------------------------------------------
step "Configuring fail2ban"
cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# 8. Unattended security upgrades
# ---------------------------------------------------------------------------
step "Enabling unattended security upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades

# ---------------------------------------------------------------------------
# 9. Podman (rootless)
# ---------------------------------------------------------------------------
step "Installing Podman"
apt-get install -y -q podman podman-plugins

# rootless containers can only bind ports >= net.ipv4.ip_unprivileged_port_start;
# lower it so a rootless Caddy/nginx can still bind 80/443.
cat >/etc/sysctl.d/98-podman-unprivileged-ports.conf <<EOF
net.ipv4.ip_unprivileged_port_start=${UNPRIVILEGED_PORT_START}
EOF
sysctl --system >/dev/null

# subuid/subgid ranges for user namespaces (adduser sets these on Debian/Ubuntu
# by default, but confirm/repair in case of an atypical base image)
grep -q "^${NEW_USER}:" /etc/subuid 2>/dev/null || usermod --add-subuids 200000-265535 "${NEW_USER}"
grep -q "^${NEW_USER}:" /etc/subgid 2>/dev/null || usermod --add-subgids 200000-265535 "${NEW_USER}"

# linger: lets the user's systemd --user instance (and its containers) keep
# running after SSH logout / without an active login session
loginctl enable-linger "${NEW_USER}"

# ---------------------------------------------------------------------------
# 10. Quadlet layout for the deploy user
# ---------------------------------------------------------------------------
step "Setting up Quadlet directories for ${NEW_USER}"
USER_HOME="/home/${NEW_USER}"
QUADLET_DIR="${USER_HOME}/.config/containers/systemd"
install -d -m 755 -o "${NEW_USER}" -g "${NEW_USER}" \
  "${USER_HOME}/.config/containers" \
  "${QUADLET_DIR}" \
  "${USER_HOME}/apps" \
  "${USER_HOME}/apps/caddy/data" \
  "${USER_HOME}/apps/caddy/config"

# shared network so app containers can reach the reverse proxy by name
cat > "${QUADLET_DIR}/web.network" <<'EOF'
[Network]
NetworkName=web
EOF

# reverse proxy: Caddy gets you automatic Let's Encrypt HTTPS for free with
# a one-line Caddyfile per app. Edit apps/caddy/Caddyfile then
# `systemctl --user restart caddy` to pick up changes.
if [ ! -f "${USER_HOME}/apps/caddy/Caddyfile" ]; then
  cat > "${USER_HOME}/apps/caddy/Caddyfile" <<'EOF'
# example.com {
#   reverse_proxy myapp:8080
# }
:80 {
  respond "OK"
}
EOF
fi

cat > "${QUADLET_DIR}/caddy.container" <<EOF
[Unit]
Description=Caddy reverse proxy
After=network-online.target

[Container]
Image=docker.io/library/caddy:2-alpine
ContainerName=caddy
Network=web.network
PublishPort=80:80
PublishPort=443:443
Volume=%h/apps/caddy/Caddyfile:/etc/caddy/Caddyfile:Z
Volume=%h/apps/caddy/data:/data:Z
Volume=%h/apps/caddy/config:/config:Z

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

# example app quadlet, disabled by default — copy/adapt this per app you deploy
cat > "${QUADLET_DIR}/example-app.container.sample" <<'EOF'
# Rename to "example-app.container" and adjust to deploy a real app.
[Unit]
Description=Example app
After=network-online.target

[Container]
Image=docker.io/library/nginx:alpine
ContainerName=example-app
Network=web.network
# no PublishPort needed: Caddy reaches it over the "web" network by
# ContainerName, e.g. `reverse_proxy example-app:80` in the Caddyfile

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

chown -R "${NEW_USER}:${NEW_USER}" "${USER_HOME}/.config" "${USER_HOME}/apps"

# periodic cleanup of dangling images/volumes so disk doesn't fill up
cat > "${QUADLET_DIR}/../podman-prune.service" <<'EOF'
EOF
rm -f "${QUADLET_DIR}/../podman-prune.service"
install -d -m 755 -o "${NEW_USER}" -g "${NEW_USER}" "${USER_HOME}/.config/systemd/user"
cat > "${USER_HOME}/.config/systemd/user/podman-prune.service" <<'EOF'
[Unit]
Description=Prune unused podman data

[Service]
Type=oneshot
ExecStart=/usr/bin/podman system prune -f
EOF
cat > "${USER_HOME}/.config/systemd/user/podman-prune.timer" <<'EOF'
[Unit]
Description=Weekly podman prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
chown -R "${NEW_USER}:${NEW_USER}" "${USER_HOME}/.config/systemd"

# activate everything as the deploy user via its own systemd --user bus
runuser -l "${NEW_USER}" -c '
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  systemctl --user daemon-reload
  systemctl --user enable --now caddy.service
  systemctl --user enable --now podman-prune.timer
'

# ---------------------------------------------------------------------------
# 11. journald log size cap (containers can log a lot)
# ---------------------------------------------------------------------------
step "Capping journald log size"
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-size-cap.conf <<'EOF'
[Journal]
SystemMaxUse=500M
EOF
systemctl restart systemd-journald

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
step "Bootstrap complete"
cat <<EOF

Summary
-------
  Deploy user       : ${NEW_USER}  (passwordless sudo, key-only SSH)
  SSH port           : ${SSH_PORT}
  Firewall            : UFW enabled, ports ${SSH_PORT},80,443 open
  Podman              : rootless, lingering enabled
  Quadlet units       : ${QUADLET_DIR}
  Reverse proxy        : caddy.service (running, systemctl --user)
  Caddyfile            : ${USER_HOME}/apps/caddy/Caddyfile

Next steps
----------
  1. From another terminal, confirm you can log in BEFORE closing this
     session:  ssh -p ${SSH_PORT} ${NEW_USER}@<server-ip>
  2. Edit ${USER_HOME}/apps/caddy/Caddyfile with your real domain(s), then:
       systemctl --user restart caddy
  3. To deploy an app: drop a container image, write a
     ~/.config/containers/systemd/<name>.container quadlet file (see
     example-app.container.sample), then:
       systemctl --user daemon-reload
       systemctl --user enable --now <name>.service
  4. Point your domain's DNS A/AAAA record at this server's IP.
     Caddy will obtain a Let's Encrypt cert automatically on first request.

Run all systemctl/podman commands from here on AS ${NEW_USER}, not root
(e.g. \`ssh ${NEW_USER}@host\`, or \`sudo -iu ${NEW_USER}\`).
EOF
