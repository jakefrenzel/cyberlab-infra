#!/usr/bin/env bash
# Creates vmbr1 on pve1: a private NAT bridge for the Talos cluster.
# VMs get outbound internet via pve1; nothing on the upstream network can reach them.
# Safe to re-run. From the laptop (repo root), with the first three octets of the cluster /24:
#   scp host/pve1/setup-vmbr1.sh root@<pve1-tailscale-ip>:/root/
#   ssh root@<pve1-tailscale-ip> bash /root/setup-vmbr1.sh <subnet, e.g. 10.127.40>
# Pick a subnet outside the k8s service (10.96.0.0/12) and pod (10.244.0.0/16) CIDRs.
set -euo pipefail

SUBNET=${1:?usage: setup-vmbr1.sh <first three octets of the cluster /24, e.g. 10.127.40>}
IFACES=/etc/network/interfaces

if ! grep -q '^auto vmbr1' "$IFACES"; then
  echo "Adding vmbr1 (${SUBNET}.0/24) ..."
  cp "$IFACES" "$IFACES.bak-$(date +%F-%H%M%S)"
  cat >> "$IFACES" <<EOF

# Private NAT network for the Talos cluster (no inbound from upstream network)
auto vmbr1
iface vmbr1 inet static
        address ${SUBNET}.1/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up   iptables -t nat -A POSTROUTING -s ${SUBNET}.0/24 -o vmbr0 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s ${SUBNET}.0/24 -o vmbr0 -j MASQUERADE
        post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
        post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
EOF
  # ifup only this bridge (not ifreload -a) so a mistake can't drop vmbr0 and lock us out
  ifup vmbr1
else
  echo "vmbr1 already configured, leaving it alone."
fi

tailscale set --advertise-routes="${SUBNET}.0/24"

echo
echo "--- checks ---"
ip -br a show vmbr1
echo "ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)"
iptables -t nat -S POSTROUTING | grep "${SUBNET}.0/24" || echo "WARNING: no MASQUERADE rule for ${SUBNET}.0/24"
echo
echo "Next: approve ${SUBNET}.0/24 for pve1 in the Tailscale admin console and add it to the"
echo "subnet-router grant in the tailnet policy, then: ping ${SUBNET}.1"
