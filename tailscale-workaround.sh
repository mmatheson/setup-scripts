#!/usr/bin/env bash
set -euo pipefail

sudo mkdir -p /dev/net
sudo mknod /dev/net/tun c 10 200 ; echo "mknod exit=$?"   # exit must be 0
sudo chmod 600 /dev/net/tun
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl restart tailscaled
sudo systemctl status tailscaled --no-pager
sudo journalctl -u tailscaled --no-pager -n 5
sudo tailscale up
