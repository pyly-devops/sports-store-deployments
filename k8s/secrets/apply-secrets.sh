#!/usr/bin/env bash
#
# Create the Secret the application needs, from the local .env file.
#
#   cp k8s/secrets/.env.example k8s/secrets/.env   # then edit it
#   ./k8s/secrets/apply-secrets.sh
#
# Why a script instead of a committed Secret manifest: a Secret manifest with
# real values in `stringData` is a plaintext credential in git. Base64 is not
# encryption, and `.env` is already the pattern Milestone 1 used for Compose.
# Generating the manifest at apply time keeps the repo clean while still
# producing exactly the resources the README's apply order expects.
#
# `--dry-run=client -o yaml | kubectl apply -f -` rather than
# `kubectl create secret`: create fails if the Secret already exists, apply is
# idempotent and can be re-run after a password change.

set -euo pipefail

NAMESPACE="${NAMESPACE:-sports-store}"
ENV_FILE="$(dirname "$0")/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found. Copy .env.example to .env and fill it in." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${JWT_SECRET:?JWT_SECRET must be set in $ENV_FILE}"
: "${MONGO_URI:?MONGO_URI must be set in $ENV_FILE}"

# MongoDB Atlas now, not a self-hosted Bitnami chart -- the connection
# string is already complete as copied from the Atlas UI, so there is
# nothing to assemble here anymore. No separate mongodb-credentials Secret
# either: Atlas manages its own root user, we only ever hold the app user's
# connection string.

# ---------------------------------------------------------------------------
# app-secrets -- consumed by the five service Deployments.
#
# One MONGO_URI key per service even though all five currently hold the SAME
# string. The database name is hardcoded in each service's database.py
# (client["auth_db"], client["catalog_db"], ...) rather than read from the URI,
# so the URIs are identical today. Separate keys are kept anyway because they
# make the database-per-service boundary explicit, they let one service's
# credentials be rotated without touching the other four, and the Helm chart in
# Milestone 3 templates them per service from a `range`.
# ---------------------------------------------------------------------------
kubectl create secret generic app-secrets \
  --namespace "$NAMESPACE" \
  --from-literal="JWT_SECRET=${JWT_SECRET}" \
  --from-literal="AUTH_MONGO_URI=${MONGO_URI}" \
  --from-literal="CATALOG_MONGO_URI=${MONGO_URI}" \
  --from-literal="CART_MONGO_URI=${MONGO_URI}" \
  --from-literal="ORDER_MONGO_URI=${MONGO_URI}" \
  --from-literal="PAYMENT_MONGO_URI=${MONGO_URI}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secrets applied to namespace ${NAMESPACE}: app-secrets"
