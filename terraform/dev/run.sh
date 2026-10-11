#!/usr/bin/env bash
# Apply -> wait for the cluster -> install ingress-nginx -> deploy the chart
# -> curl-verify, in one run. Leaves the dev environment up on exit by
# default — nothing here is meant to outlive a debugging session, but
# destroying it is on you to request explicitly, via --destroy.
#
# Usage: ./run.sh [--destroy] [--help]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(cd ../.. && pwd)"

print_help() {
  cat <<'EOF'
Usage: ./run.sh [--destroy] [--help]

Applies the dev Terraform, waits for the cluster, installs
ingress-nginx, deploys the chart, curl-verifies it, then leaves the
dev environment up.

With --destroy, this WILL run 'terraform destroy' on the dev
environment automatically when the script exits for any reason, including
a failed step or Ctrl-C.

  --destroy    Run 'terraform destroy' on exit (success, failure, or
               Ctrl-C) instead of leaving the environment up.
  --help       Show this message and exit (no destroy, nothing is touched).
EOF
}

DESTROY=false
for arg in "$@"; do
  case "$arg" in
    --help|-h) print_help; exit 0 ;;
    --destroy) DESTROY=true ;;
    *) echo "Unknown argument: $arg" >&2; print_help >&2; exit 1 ;;
  esac
done

for cmd in terraform ssh scp kubectl helm curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

if [ ! -f terraform.tfvars ]; then
  echo "terraform.tfvars not found, copy terraform.tfvars.example and edit allowed_admin_cidr and ssh_public_key_path first." >&2
  exit 1
fi

# Private key matching terraform.tfvars' ssh_public_key_path, overridable
# via the environment. This is YOUR key for human access — a separate,
# Terraform-generated key pair now handles the worker fetching its join
# token from the control plane (main.tf's tls_private_key.node_to_node),
# unrelated to this one.
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_lab}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# A fresh instance with a new IP every run has no prior known_hosts entry
# to check anyway, so skipping host-key verification here isn't giving up
# anything this environment actually had — same tradeoff kind-deploy-verify
# never has to make, since kind never leaves your own machine.
ssh_cp() {
  ssh "${SSH_OPTS[@]}" "ec2-user@$CP_IP" "$@"
}

wait_for_ssh() {
  for _ in $(seq 1 30); do
    ssh_cp true 2>/dev/null && return 0
    sleep 10
  done
  echo "SSH to the control plane never came up" >&2
  return 1
}

cleanup() {
  if [ "$DESTROY" != true ]; then
    echo "==> leaving the environment up. Run 'terraform destroy' in this directory when done, or re-run with --destroy next time."
    return
  fi
  echo "==> destroying (terraform destroy)"
  terraform destroy -auto-approve
  rm -f kubeconfig-dev.yaml /tmp/csat-values-dev.rendered.yaml
}
echo "==> terraform init"
terraform init -input=false

trap cleanup EXIT

echo "==> terraform apply"
terraform apply -auto-approve

CP_IP=$(terraform output -raw control_plane_public_ip)
WORKER_IP=$(terraform output -raw worker_public_ip)
echo "control plane: $CP_IP"
echo "worker:        $WORKER_IP"

echo "==> waiting for SSH on the control plane"
wait_for_ssh

echo "==> waiting for k3s to write its kubeconfig"
for _ in $(seq 1 30); do
  ssh_cp test -f /etc/rancher/k3s/k3s.yaml && break
  sleep 10
done

echo "==> fetching kubeconfig"
ssh_cp cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127.0.0.1/$CP_IP/" > kubeconfig-dev.yaml
export KUBECONFIG="$PWD/kubeconfig-dev.yaml"

echo "==> waiting for both nodes to be Ready"
for _ in $(seq 1 30); do
  [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')" -ge 2 ] && break
  sleep 10
done
kubectl get nodes

echo "==> installing ingress-nginx (bare-metal/hostNetwork, no cloud LB here)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
# admissionWebhooks disabled: its pre-install Job (cert generation, patching
# the ValidatingWebhookConfiguration) is a well-known source of hangs on a
# small/fresh single-node cluster, and the webhook itself isn't needed here
# — this is a throwaway test cluster deploying one already-correct Ingress,
# not a multi-tenant cluster that needs admission-time validation.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.service.type=ClusterIP \
  --set controller.admissionWebhooks.enabled=false \
  --wait --timeout 3m

echo "==> deploying the chart"
sed "s/REPLACE_ME_WORKER_IP/$WORKER_IP/g" "$ROOT/kubernetes/chart/values-dev.yaml" \
  > /tmp/csat-values-dev.rendered.yaml
helm upgrade --install csat "$ROOT/kubernetes/chart" \
  -f /tmp/csat-values-dev.rendered.yaml \
  --wait --timeout 8m

echo "==> verifying"
FAIL=0
check() {
  local url="$1" want="$2" code=000
  for _ in $(seq 1 10); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || echo 000)
    if [ "$code" = "$want" ]; then
      echo "  $url -> HTTP $code"
      return 0
    fi
    sleep 5
  done
  echo "  $url -> HTTP $code (expected $want)" >&2
  FAIL=1
}
check "http://api.$WORKER_IP.nip.io/healthz" 200
check "http://api.$WORKER_IP.nip.io/api/static-pages" 200
check "http://app.$WORKER_IP.nip.io/" 200

if [ "$FAIL" -ne 0 ]; then
  echo "==> verification FAILED" >&2
  exit 1
fi
echo "==> verification passed"
