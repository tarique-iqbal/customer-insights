#!/usr/bin/env bash
# Apply -> wait for the EKS cluster and its node group -> install the AWS
# Load Balancer Controller -> deploy the chart -> curl-verify, in one run.
# Leaves staging up on exit by default — unlike dev this tier isn't meant
# to be destroyed after every session (see notes/aws-qna.md's "isn't as
# disposable" note), so destroying it is on you to request explicitly, via
# --destroy.
#
# Usage: ./run.sh [--destroy] [--help]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(cd ../.. && pwd)"

print_help() {
  cat <<'EOF'
Usage: ./run.sh [--destroy] [--help]

Applies the staging Terraform, waits for the EKS cluster and its node
group, installs the AWS Load Balancer Controller, deploys the chart,
curl-verifies it, then leaves the staging environment up.

With --destroy, this WILL run 'terraform destroy' on the staging
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

for cmd in terraform aws kubectl helm curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

if [ ! -f terraform.tfvars ]; then
  echo "terraform.tfvars not found, copy terraform.tfvars.example and edit allowed_admin_cidr first." >&2
  exit 1
fi

# Set before the trap below so cleanup (which can run before this is ever
# assigned a real value, e.g. if terraform apply itself fails) has
# something defined to check under 'set -u' rather than erroring on an
# unbound variable.
CLUSTER_CONTEXT=""

cleanup() {
  if [ "$DESTROY" != true ]; then
    echo "==> leaving the environment up. Run 'terraform destroy' in this directory when done, or re-run with --destroy next time."
    return
  fi
  echo "==> destroying (terraform destroy)"
  # The ALB Ingress creates a real load balancer outside Terraform's view
  # (Helm/the controller created it, not aws_lb) — uninstall the chart
  # first so the controller tears the ALB down itself before terraform
  # destroy removes the VPC/subnets underneath it. Skipping this step
  # leaves an orphaned ALB that still bills, and can also make the VPC
  # delete fail with "has dependent objects".
  if [ -n "$CLUSTER_CONTEXT" ]; then
    helm uninstall csat --kube-context "$CLUSTER_CONTEXT" >/dev/null 2>&1 || true
  fi
  terraform destroy -auto-approve
}

echo "==> terraform init"
terraform init -input=false

trap cleanup EXIT

echo "==> terraform apply"
terraform apply -auto-approve

AWS_REGION=$(terraform output -raw aws_region)
CLUSTER_NAME=$(terraform output -raw cluster_name)
VPC_ID=$(terraform output -raw vpc_id)
ALB_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)
echo "cluster:  $CLUSTER_NAME"
echo "region:   $AWS_REGION"
echo "vpc:      $VPC_ID"

echo "==> writing kubeconfig (aws eks update-kubeconfig)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
CLUSTER_CONTEXT=$(kubectl config current-context)

echo "==> waiting for the node group to be Ready"
for _ in $(seq 1 30); do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
  [ "$READY" -ge 1 ] && break
  sleep 10
done
kubectl get nodes

echo "==> ensuring a default StorageClass exists (EKS ships none by default, unlike kind/dev)"
# The aws-ebs-csi-driver EKS add-on (terraform/staging/main.tf) provides the
# provisioner but not a StorageClass object itself — mysql's PVC needs the
# cluster's *default* one to bind (see that template's own comment).
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
EOF

echo "==> installing the AWS Load Balancer Controller (IRSA role from terraform output)"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_ROLE_ARN" \
  --wait --timeout 3m

echo "==> deploying the chart"
helm upgrade --install csat "$ROOT/kubernetes/chart" \
  -f "$ROOT/kubernetes/chart/values-staging.yaml" \
  --wait --timeout 8m

echo "==> waiting for the ALB Ingress to get a real hostname"
ALB_HOST=""
for _ in $(seq 1 30); do
  ALB_HOST=$(kubectl get ingress csat -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$ALB_HOST" ] && break
  sleep 10
done
if [ -z "$ALB_HOST" ]; then
  echo "ALB hostname never appeared on the Ingress" >&2
  exit 1
fi
echo "ALB hostname: $ALB_HOST"

echo "==> verifying"
# No DNS points at api.csat-staging.internal / app.csat-staging.internal
# (values-staging.yaml's placeholder hostnames) yet — curl can still prove
# the routing works by hitting the ALB's own DNS name directly and setting
# the Host header the Ingress actually matches on. Pointing real DNS at
# this ALB is a later step, not needed for this to verify correctly.
FAIL=0
check() {
  local host="$1" path="$2" want="$3" code=000
  for _ in $(seq 1 10); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" "http://$ALB_HOST$path" || echo 000)
    if [ "$code" = "$want" ]; then
      echo "  $host$path -> HTTP $code"
      return 0
    fi
    sleep 5
  done
  echo "  $host$path -> HTTP $code (expected $want)" >&2
  FAIL=1
}
check api.csat-staging.internal /healthz 200
check api.csat-staging.internal /api/static-pages 200
check app.csat-staging.internal / 200

if [ "$FAIL" -ne 0 ]; then
  echo "==> verification FAILED" >&2
  exit 1
fi
echo "==> verification passed"
