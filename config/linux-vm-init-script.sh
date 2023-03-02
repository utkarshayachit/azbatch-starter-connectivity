#!/bin/sh

echo "Script triggered by cloud-init process"


# Install required packages and ensure installed packages are updated

apt update
apt upgrade -y
apt install  azure-cli nfs-common jq -y

