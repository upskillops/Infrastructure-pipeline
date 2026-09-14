#!/usr/bin/env bash
# Creates the two secrets values-gitlab.yaml references. Run once before
# `helm install`, with real values swapped in. Never commit this file
# with real secrets filled in - keep it out of git (already covered by
# a generic *.sh ignore if you add one, or just don't commit it).
set -euo pipefail

NAMESPACE=gitlab
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# RDS master password (pull the real value from Secrets Manager if you used
# `manage_master_user_password = true` in the rds module: `aws secretsmanager
# get-secret-value --secret-id <module.rds.master_user_secret_arn>`)
kubectl create secret generic gitlab-postgres-password \
  --namespace "$NAMESPACE" \
  --from-literal=password='REPLACE_ME' \
  --dry-run=client -o yaml | kubectl apply -f -

# S3 connection config (IAM role for service account is simpler/more secure
# than static keys if you're using IRSA - swap this for a role-based
# connection block if you go that route instead)
kubectl create secret generic gitlab-object-storage \
  --namespace "$NAMESPACE" \
  --from-literal=connection='provider: AWS
region: us-east-1
aws_access_key_id: REPLACE_ME
aws_secret_access_key: REPLACE_ME' \
  --dry-run=client -o yaml | kubectl apply -f -
