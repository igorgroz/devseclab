#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION="${AWS_REGION:-ap-southeast-2}"
CLUSTER_NAME="${CLUSTER_NAME:-dsl-eks}"

log() {
  printf '\n==> %s\n' "$1"
}

run_or_warn() {
  if ! "$@"; then
    printf 'WARN: command failed but continuing: %s\n' "$*" >&2
  fi
}

cd "${ROOT_DIR}"

log "Updating kubeconfig for ${CLUSTER_NAME} (${AWS_REGION})"
run_or_warn aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

log "Deleting ingress"
run_or_warn kubectl delete -f k8s/ingress.yaml --ignore-not-found=true

log "Deleting workloads"
run_or_warn kubectl delete -f k8s/frontend/ --ignore-not-found=true
run_or_warn kubectl delete -f k8s/backend/ --ignore-not-found=true
run_or_warn kubectl delete -f k8s/db/ --ignore-not-found=true

log "Deleting External Secrets resources"
run_or_warn kubectl delete -f k8s/eso/externalsecret-db-password.yaml --ignore-not-found=true
run_or_warn kubectl delete -f k8s/eso/externalsecret-jwt-secret.yaml --ignore-not-found=true
run_or_warn kubectl delete -f k8s/eso/clustersecretstore.yaml --ignore-not-found=true

log "Uninstalling Helm releases"
run_or_warn helm uninstall aws-load-balancer-controller -n kube-system
run_or_warn helm uninstall external-secrets -n external-secrets

log "Giving AWS and Kubernetes time to release ALB/ENI dependencies"
sleep 60

log "Running terraform destroy"
terraform -chdir=terraform/infra-lab init -input=false
terraform -chdir=terraform/infra-lab destroy -auto-approve -input=false

log "Deleting orphaned VPC flow-log group if it still exists"
run_or_warn aws logs delete-log-group \
  --log-group-name "/aws/vpc/flow-logs/${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

log "Done"
