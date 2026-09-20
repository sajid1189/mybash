#!/usr/bin/env bash

set -euo pipefail

sudo apt update
sudo apt install -y podman dbus-user-session

echo "############ Restarting Podman Service #######################"
sudo systemctl enable podman-restart.service

# Create the default network (skipped if it already exists)

echo "############ Creating Podman Network #######################"
podman network exists mypods || podman network create mypods

echo "############ Creating  Volume jenkins_home #######################"
podman volume exists jenkins_home || podman volume create jenkins_home


echo "################### Starting Podman Systemd Service #########################"
podman rm -f jenkins || true
mkdir -p ~/.config/containers/systemd
cat << 'EOF' > ~/.config/containers/systemd/jenkins.container
[Unit]
Description=Jenkins

[Container]
Image=docker.io/jenkins/jenkins:lts-jdk21
ContainerName=jenkins
PublishPort=127.0.0.1:8080:8080
PublishPort=50000:50000
Volume=jenkins_home:/var/jenkins_home

[Service]
Restart=always

[Install]
WantedBy=default.target

EOF


echo "###################### Daemon reload #################"
# Linger starts a persistent systemd user instance (survives logout/reboot).
# It must exist before any `systemctl --user` call, and the shell needs to
# know where its bus socket is (missing over plain ssh / su / sudo su).
sudo loginctl enable-linger "$(id -un)"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# The user manager starts asynchronously; wait for its bus socket.
for _ in $(seq 1 30); do
    [ -S "${XDG_RUNTIME_DIR}/bus" ] && break
    sleep 1
done
[ -S "${XDG_RUNTIME_DIR}/bus" ] || { echo "systemd user bus not available" >&2; exit 1; }

systemctl --user daemon-reload
systemctl --user restart jenkins
systemctl --user status jenkins

##################### Commands ################

# podman logs -f jenkins
# podman restart jenkins
# podman pull docker.io/jenkins/jenkins:lts-jdk21   # fetch the newest LTS, then recreate the container