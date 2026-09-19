#!/usr/bin/env bash
#
# hetzner-podman-bootstrap.sh
#
# Bootstraps a fresh Hetzner Cloud VPS (Debian 12 / Ubuntu 22.04+) into a
# host for rootless Podman containers, managed via systemd Quadlet units
# (no docker-compose / podman-compose needed).
#
# This host does NOT terminate HTTPS or run a reverse proxy. A separate
# nginx VPS handles TLS and forwards traffic to the containers here, so the
# firewall only lets that proxy (PROXY_IP) reach the app ports.
#
# Usage (as root, right after first boot):
#   scp hetzner-podman-bootstrap.sh root@<ip>:~
#   ssh root@<ip>
#   chmod +x hetzner-podman-bootstrap.sh
#   NEW_USER=deploy SSH_PORT=22 ./hetzner-podman-bootstrap.sh
#
# Re-running is safe: every step checks current state before changing it.
#
# Configuration (override via environment variables):
#   NEW_USER          Non-root deploy user to create        (default: deploy)
#   SSH_PORT           SSH port sshd will listen on           (default: 22)
#   TIMEZONE           System timezone                        (default: UTC)
#   SWAP_SIZE_MB        Swapfile size in MB, 0 disables it     (default: auto, min(2*RAM,4096))
#   ADMIN_SSH_KEY       Public key to authorize for NEW_USER   (default: copy root's authorized_keys)
#   PROXY_IP            IP of the nginx VPS allowed to reach APP_PORTS (default: none, ports stay closed)
#   APP_PORTS           Port range containers publish, UFW syntax (default: 8000:8999)
#

# `set` changes shell behavior for the rest of the script. Each letter is a
# separate flag bundled together:
#   -e  exit immediately if any command fails (returns non-zero)
#   -u  treat using an undefined variable as an error, instead of silently
#       treating it as an empty string
#   -o pipefail  in a pipeline like `a | b`, fail the whole pipeline if `a`
#       fails, not just if the last command `b` fails
# Without this, a failed command (e.g. a typo'd path) would be ignored and
# the script would plow ahead in a half-configured state.
set -euo pipefail

# Config
#
# `NAME="${NAME:-default}"` is bash's "use this value, or fall back to a
# default" syntax. It expands the variable NAME; if NAME is unset or empty,
# it substitutes "default" instead. Wrapping the assignment around it means:
# "keep NAME's value if the caller already set it in the environment
# (e.g. `NEW_USER=alice ./script.sh`), otherwise set it to this default."
# This is what makes every setting below overridable without editing the file.
NEW_USER="${NEW_USER:-deploy}"
SSH_PORT="${SSH_PORT:-22}"
TIMEZONE="${TIMEZONE:-UTC}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-}"
ADMIN_SSH_KEY="${ADMIN_SSH_KEY:-}"
PROXY_IP="${PROXY_IP:-}"
APP_PORTS="${APP_PORTS:-8000:8999}"

# Preflight
#
# `[ ... ]` is the `test` command (it's literally a program named `[`, and
# the closing `]` is just its last argument). It evaluates a condition and
# exits 0 (true) or 1 (false); `if` acts on that exit status.
# `$(id -u)` is command substitution: bash runs `id -u` (prints the current
# user's numeric ID) and substitutes its output into the string. Root is
# always UID 0, so this checks "am I root?".
if [ "$(id -u)" -ne 0 ]; then
  # `>&2` redirects this echo's output to file descriptor 2, i.e. stderr,
  # which is the convention for error messages (as opposed to normal
  # output on stdout, file descriptor 1).
  echo "ERROR: run this script as root (fresh Hetzner image logs you in as root)." >&2
  exit 1
fi

# `command -v apt-get` prints the path to apt-get if it exists, and exits
# non-zero if it doesn't — the standard portable way to check "is this
# program installed?" `>/dev/null 2>&1` throws away both stdout and stderr
# (we only care about the exit status, not the printed path). `!` negates
# the condition, so this block runs when apt-get is NOT found.
if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: this script targets Debian/Ubuntu (apt-get not found)." >&2
  exit 1
fi

# A leading `.` (dot) "sources" a file: it runs the file's contents in the
# current shell, as if you'd typed it here, so any variables it sets
# (like PRETTY_NAME below) become available to the rest of this script.
# /etc/os-release is a standard file every Linux distro ships with
# NAME/VERSION/PRETTY_NAME variables describing the OS.
. /etc/os-release
echo "==> Detected ${PRETTY_NAME}"

# 1. System update + base packages
echo "==> Updating base system"
# Exporting DEBIAN_FRONTEND=noninteractive tells Debian/Ubuntu package
# scripts not to pop up interactive prompts (e.g. "restart services?").
# `export` makes the variable part of the environment passed to child
# processes (apt-get below), not just visible inside this script.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
# The trailing `\` at the end of a line is a line continuation: it tells
# bash "this command isn't finished, keep reading the next line as part
# of it." Purely for readability — this is one long `apt-get install` call.
apt-get install -y \
  curl wget gnupg2 ca-certificates lsb-release \
  ufw fail2ban unattended-upgrades apt-listchanges \
  uidmap slirp4netns fuse-overlayfs \
  chrony jq git

# 2. Timezone
echo "==> Setting timezone to ${TIMEZONE}"
timedatectl set-timezone "${TIMEZONE}"

# 3. Swap (Hetzner's cheaper plans are RAM-constrained; a swapfile keeps
# the OOM killer from taking out containers under a memory spike)
echo "==> Configuring swap"
# `-z` tests whether a string is empty. Here: "if the caller didn't set
# SWAP_SIZE_MB, calculate a sensible default."
if [ -z "${SWAP_SIZE_MB}" ]; then
  # Command substitution again: run `awk ...` and capture its output into
  # the variable mem_mb. awk scans /proc/meminfo for the MemTotal line and
  # prints it converted from KB to MB.
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  # `$(( ... ))` is arithmetic expansion: bash evaluates the expression as
  # a number (as opposed to `$( ... )`, which runs a command).
  SWAP_SIZE_MB=$(( mem_mb * 2 ))
  # `&&` runs the second command only if the first one succeeds (exits 0).
  # Used here as a compact one-line if-statement: "if SWAP_SIZE_MB > 4096,
  # then cap it at 4096."
  [ "${SWAP_SIZE_MB}" -gt 4096 ] && SWAP_SIZE_MB=4096
fi

if [ "${SWAP_SIZE_MB}" -eq 0 ]; then
  echo "WARN: SWAP_SIZE_MB=0, skipping swap setup"
# A pipeline `a | b` feeds command a's stdout into command b's stdin.
# Here: list active swap devices, then have grep search that list for
# "/swapfile" and exit 0 only if it finds a match (-q means "quiet",
# don't print the match, we only want its exit status).
elif swapon --show=NAME --noheadings | grep -q '/swapfile'; then
  echo "swapfile already active, skipping"
else
  # `||` is the opposite of `&&`: run the second command only if the first
  # one FAILS. fallocate is fast but not supported on every filesystem;
  # if it fails, fall back to the slower but universally-supported dd.
  fallocate -l "${SWAP_SIZE_MB}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}"
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  # Another `grep -q ... || echo ...` pattern: "if this line isn't already
  # in /etc/fstab, append it." `>>` appends to a file; a single `>` would
  # overwrite it, which we don't want here.
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # low swappiness: prefer RAM, use swap only as a safety net for containers
  #
  # `cat > file <<'EOF' ... EOF` is a "heredoc": everything between the two
  # EOF markers is fed to cat as input, which then writes it to `file` via
  # the `>` redirect. Quoting the opening EOF as 'EOF' disables variable
  # expansion inside the block — useful for config files that use `$` in
  # ways bash shouldn't touch. (Further down you'll see heredocs WITHOUT
  # the quotes, where ${VARS} inside the block DO get substituted.)
  cat >/etc/sysctl.d/99-swap.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
  sysctl --system
fi

# 4. Deploy user
echo "==> Creating deploy user '${NEW_USER}'"
if id "${NEW_USER}" >/dev/null 2>&1; then
  echo "user ${NEW_USER} already exists"
else
  adduser --disabled-password --gecos "" "${NEW_USER}"
  usermod -aG sudo "${NEW_USER}"
fi

install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "/home/${NEW_USER}/.ssh"
AUTH_KEYS="/home/${NEW_USER}/.ssh/authorized_keys"

# `-n` tests whether a string is non-empty (opposite of `-z` above).
if [ -n "${ADMIN_SSH_KEY}" ]; then
  echo "${ADMIN_SSH_KEY}" >> "${AUTH_KEYS}"
# `-s` tests that a file exists AND is non-empty (size > 0).
elif [ -s /root/.ssh/authorized_keys ]; then
  cat /root/.ssh/authorized_keys >> "${AUTH_KEYS}"
else
  echo "WARN: no ADMIN_SSH_KEY provided and /root/.ssh/authorized_keys is empty."
  echo "WARN: you MUST add a key to ${AUTH_KEYS} before disabling password auth, or you will lock yourself out."
fi
# `sort -u -o FILE FILE` sorts a file and writes the result back to the
# same file, de-duplicating lines (-u). `2>/dev/null || true` means: if
# this fails for any reason (e.g. the file doesn't exist yet), throw away
# the error and force success anyway, so `set -e` doesn't kill the script.
sort -u -o "${AUTH_KEYS}" "${AUTH_KEYS}" 2>/dev/null || true
chmod 600 "${AUTH_KEYS}"
chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"

# passwordless sudo for the deploy user simplifies unattended app deploys;
# drop this file if you want sudo to prompt for a password instead.
echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${NEW_USER}"
chmod 440 "/etc/sudoers.d/90-${NEW_USER}"

# 5. SSH hardening
echo "==> Hardening sshd (port ${SSH_PORT}, key-only, root allowed with key)"
if [ ! -s "${AUTH_KEYS}" ]; then
  echo "WARN: skipping PasswordAuthentication=no because ${AUTH_KEYS} is empty (would lock you out)."
else
  SSHD_DROPIN=/etc/ssh/sshd_config.d/99-hardening.conf
  # This heredoc uses unquoted EOF, so ${SSH_PORT} below is substituted
  # with its actual value before being written to the file.
  cat > "${SSHD_DROPIN}" <<EOF
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding yes
MaxAuthTries 4
LoginGraceTime 20
EOF
  sshd -t # validate config before reloading
  systemctl reload ssh || systemctl reload sshd
fi

# 6. Firewall (UFW)
echo "==> Configuring UFW firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
# No public 80/443 here: TLS is handled by the nginx VPS. Only that VPS may
# reach the ports where containers publish their apps.
if [ -n "${PROXY_IP}" ]; then
  ufw allow from "${PROXY_IP}" to any port "${APP_PORTS}" proto tcp comment 'nginx proxy -> apps'
else
  echo "WARN: PROXY_IP not set, so no app ports are open. Your nginx VPS cannot reach the containers yet."
  echo "WARN: re-run with PROXY_IP=<nginx-vps-ip>, or run: ufw allow from <ip> to any port ${APP_PORTS} proto tcp"
fi
ufw --force enable

# 7. fail2ban for sshd
echo "==> Configuring fail2ban"
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

# 8. Unattended security upgrades
echo "==> Enabling unattended security upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades

# 9. Podman (rootless)
echo "==> Installing Podman"
apt-get install -y podman podman-plugins

# subuid/subgid ranges for user namespaces (adduser sets these on Debian/Ubuntu
# by default, but confirm/repair in case of an atypical base image)
#
# `^${NEW_USER}:` is a regular expression anchored to the start of the
# line (`^`), so it only matches an actual entry for this user, not the
# username appearing elsewhere in the file.
grep -q "^${NEW_USER}:" /etc/subuid 2>/dev/null || usermod --add-subuids 200000-265535 "${NEW_USER}"
grep -q "^${NEW_USER}:" /etc/subgid 2>/dev/null || usermod --add-subgids 200000-265535 "${NEW_USER}"

# linger: lets the user's systemd --user instance (and its containers) keep
# running after SSH logout / without an active login session
loginctl enable-linger "${NEW_USER}"

# 10. Quadlet layout for the deploy user
echo "==> Setting up Quadlet directories for ${NEW_USER}"
USER_HOME="/home/${NEW_USER}"
QUADLET_DIR="${USER_HOME}/.config/containers/systemd"
# `install -d` creates directories (like mkdir -p) while also setting mode
# (-m), owner (-o) and group (-g) in one step. The trailing `\` line
# continuations again just spread one long command across several lines —
# this is still a single `install` call with three directory arguments.
install -d -m 755 -o "${NEW_USER}" -g "${NEW_USER}" \
  "${USER_HOME}/.config/containers" \
  "${QUADLET_DIR}" \
  "${USER_HOME}/apps"

# example app quadlet, disabled by default — copy/adapt this per app you deploy
cat > "${QUADLET_DIR}/example-app.container.sample" <<'EOF'
# Rename to "example-app.container" and adjust to deploy a real app.
[Unit]
Description=Example app
After=network-online.target

[Container]
Image=docker.io/library/nginx:alpine
ContainerName=example-app
# host_port:container_port. The host port must be inside APP_PORTS (default
# 8000-8999). The nginx VPS then proxies to it, e.g.
#   proxy_pass http://<this-vps-ip>:8080;
PublishPort=8080:80

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

chown -R "${NEW_USER}:${NEW_USER}" "${USER_HOME}/.config" "${USER_HOME}/apps"

# periodic cleanup of dangling images/volumes so disk doesn't fill up
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
#
# `runuser -l USER -c 'commands'` runs the quoted string as a shell command,
# logged in as USER, instead of as root. We're root at this point in the
# script, but systemd --user services belong to and must be controlled by
# the target user, not root. Single quotes ('...') mean bash does NOT
# expand ${...} inside this block right now — it's passed through literally
# and evaluated later, inside the sub-shell that runuser starts as
# ${NEW_USER}. That's important for $(id -u) here: we want id -u to run
# as the deploy user (later), not be substituted with root's UID (now).
runuser -l "${NEW_USER}" -c '
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  systemctl --user daemon-reload
  systemctl --user enable --now podman-prune.timer
'

# 11. journald log size cap (containers can log a lot)
echo "==> Capping journald log size"
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-size-cap.conf <<'EOF'
[Journal]
SystemMaxUse=500M
EOF
systemctl restart systemd-journald

# Done
echo "==> Bootstrap complete"
# A final heredoc, this time piped straight to `cat` with no output
# redirect, so it prints to the terminal instead of writing to a file.
cat <<EOF

Summary
  Deploy user       : ${NEW_USER}  (passwordless sudo, key-only SSH)
  SSH port           : ${SSH_PORT}
  Firewall            : UFW enabled, SSH ${SSH_PORT} open
  App ports           : ${APP_PORTS} open to ${PROXY_IP:-nobody (PROXY_IP not set)}
  Podman              : rootless, lingering enabled
  Quadlet units       : ${QUADLET_DIR}

Next steps
  1. From another terminal, confirm you can log in BEFORE closing this
     session:  ssh -p ${SSH_PORT} ${NEW_USER}@<server-ip>
  2. To deploy an app: write a
     ~/.config/containers/systemd/<name>.container quadlet file (see
     example-app.container.sample), with a PublishPort inside ${APP_PORTS}, then:
       systemctl --user daemon-reload
       systemctl --user enable --now <name>.service
  3. On the nginx VPS, add a proxy_pass to http://<this-vps-ip>:<host-port>
     for each app. HTTPS stays on the nginx VPS.

Run all systemctl/podman commands from here on AS ${NEW_USER}, not root
(e.g. \`ssh ${NEW_USER}@host\`, or \`sudo -iu ${NEW_USER}\`).
EOF
