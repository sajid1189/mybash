#!/usr/bin/env bash

set -euo pipefail

sudo apt update
sudo apt install -y podman

echo ############ Restarting Podman Service #######################
systemctl enable podman-restart.service

# Create the default network (skipped if it already exists)

echo ############ Creating Podman Network #######################
podman network exists mypods || podman network create mypods

echo ############ Creating  Volume jenkins_home #######################
podman volume exists jenkins_home || podman volume create jenkins_home


echo ############ Opening Jenkins #######################
sudo ufw allow 8080/tcp
