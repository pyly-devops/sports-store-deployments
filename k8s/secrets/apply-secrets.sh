#!/usr/bin/env bash
#
# MINIKUBE/M2 ARTIFACT — SUPERSEDED ON EKS. As of Milestone 7, the
# `sports-store-prod` cluster gets these two Secrets from External Secrets
# Operator (cluster/external-secrets/) reading AWS Secrets Manager, not from
# this script. Running this against that cluster fights ESO's
# creationPolicy: Owner and produces a T16-style Secret-ownership conflict.
# Kept for local minikube use only.
#
# Create the two Secrets the application needs, from the local .env file.
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
: "${MONGO_ROOT_USERNAME:?MONGO_ROOT_USERNAME must be set in $ENV_FILE}"
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD must be set in $ENV_FILE}"

# The Bitnami MongoDB chart is installed as release "mongodb" in this
# namespace, which gives its Service the DNS name `mongodb`. authSource=admin
# because the root user lives in the admin database, not in the application
# databases.
MONGO_HOST="mongodb:27017"
MONGO_URI="mongodb://${MONGO_ROOT_USERNAME}:${MONGO_ROOT_PASSWORD}@${MONGO_HOST}/?authSource=admin"

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

# ---------------------------------------------------------------------------
# mongodb-credentials -- consumed by the Bitnami chart via auth.existingSecret.
#
# Separate from app-secrets because the key name is not ours to choose: the
# chart looks for exactly `mongodb-root-password`. Mixing a chart-dictated key
# into the application's own Secret would couple the two for no benefit.
# ---------------------------------------------------------------------------
kubectl create secret generic mongodb-credentials \
  --namespace "$NAMESPACE" \
  --from-literal="mongodb-root-password=${MONGO_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secrets applied to namespace ${NAMESPACE}: app-secrets, mongodb-credentials"
