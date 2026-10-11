#!/bin/bash
set -euxo pipefail

# IMDSv2 is enforced on this account's instances — a plain unauthenticated
# GET to the metadata IP silently returns nothing (not an error curl
# reports), which previously produced an empty --tls-san and a cert that
# only covered k3s's internal IPs. Fetch a token first.
IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

if [ -z "$PUBLIC_IP" ]; then
  echo "Failed to resolve the instance's public IP from IMDS" >&2
  exit 1
fi

# Trust the worker's node-to-node key, so it can SSH in later to fetch the
# join token directly (replaces an earlier SSM Parameter Store handoff,
# which an account-level Service Control Policy turned out to block).
echo "${node_public_key}" >> /home/ec2-user/.ssh/authorized_keys

# --disable traefik: k3s bundles its own Traefik ingress controller by
# default, which we never use (this chart installs ingress-nginx instead)
# — without this it just sits there as two more helm-install Jobs and a
# controller Pod competing for resources on an already-tight node.
#
# --tls-san: the kubeconfig's server certificate must cover whatever
# address kubectl/helm actually connect through — rewriting the
# kubeconfig's 127.0.0.1 to the public IP later would otherwise fail TLS
# verification.
#
# --flannel-backend=host-gw: VXLAN (the default) showed intermittent
# cross-node pod connectivity failures — host-gw uses plain IP routing
# between nodes instead of UDP encapsulation, which works well when nodes
# share an L2 network (true here, same subnet). Note this also requires
# a Security Group rule allowing traffic from the pod CIDR between nodes
# (see the ingress rules on both security groups in main.tf) — host-gw
# forwards pod-to-pod packets unencapsulated, so they arrive with a pod
# IP as their source, not the node's own host IP, unlike VXLAN. Set once
# on the server; agents pick it up from the cluster's own flannel config,
# no change needed on the worker.
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${k3s_version}" sh -s - server \
  --write-kubeconfig-mode 644 \
  --tls-san "$PUBLIC_IP" \
  --disable traefik \
  --flannel-backend=host-gw
