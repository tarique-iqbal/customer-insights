#!/bin/bash
set -euxo pipefail

# Node-to-node private key, used only to SSH into the control plane and
# fetch the join token — created before writing the (secret) key content
# into it, so the file never briefly has insecure default permissions.
install -m 600 /dev/null /root/node_key
cat > /root/node_key << 'EOF'
${node_private_key}
EOF

SSH_OPTS=(-i /root/node_key -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

TOKEN=""
for i in $(seq 1 30); do
  TOKEN=$(ssh "$${SSH_OPTS[@]}" "ec2-user@${control_plane_ip}" \
    "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null) || true
  if [ -n "$TOKEN" ]; then
    break
  fi
  sleep 10
done

if [ -z "$TOKEN" ]; then
  echo "Timed out fetching the join token from the control plane over SSH" >&2
  exit 1
fi

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${k3s_version}" \
  K3S_URL="https://${control_plane_ip}:6443" \
  K3S_TOKEN="$TOKEN" \
  sh -
