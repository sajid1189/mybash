#!/usr/bin/env bash
# Bootstrap a fresh Hetzner VPS (Ubuntu 26.04) for running Podman containers.
# Run as root: bash bootstrap.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade
apt-get -y install podman

# Restart containers with --restart=always after a reboot
systemctl enable podman-restart.service

# Create the default network (skipped if it already exists)
podman network exists mypods || podman network create mypods

podman --version
podman network ls
