#!/usr/bin/env bash
# Phase 6 bootstrap: one-time resources Terraform needs before it can run.
#   4.1 S3 state bucket   4.2 GitHub OIDC provider
#   4.3 plan role (PRs)   4.4 apply role (production environment)   4.5 policy checks
# Run in CloudShell from inside this folder:  bash bootstrap.sh
# Safe to re-run: existing resources are updated, not duplicated.
set -euo pipefail

ACCOUNT_ID=832866945974
REGION=ca-central-1
BUCKET=aura-tfstate-ak-seng4620-x7k2
OIDC_HOST=token.actions.githubusercontent.com
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

# --- Pre-flight: right account, every file present and valid JSON -------------
CURRENT=$(aws sts get-caller-identity --query Account --output text)
[ "$CURRENT" = "$ACCOUNT_ID" ] || { echo "Wrong AWS account: $CURRENT"; exit 1; }
for f in tfstate-bucket-policy.json github-plan-trust.json github-apply-trust.json \
         plan-role-policy.json apply-role-policy.json; do
  [ -s "$f" ] || { echo "Missing or empty: $f"; exit 1; }
  jq empty "$f" || { echo "Invalid JSON: $f"; exit 1; }
done
echo "Pre-flight OK (account $CURRENT)"

# Show how the ledger role's permissions are attached. Expected: one inline
# policy (aura-ledger-secrets-read) plus AmazonSSMManagedInstanceCore, which is
# the only managed policy apply-role-policy.json lets Terraform attach.
echo "== aura-ledger-ec2-role policies (inline, then attached)"
aws iam list-role-policies --role-name aura-ledger-ec2-role --query 'PolicyNames' --output text
aws iam list-attached-role-policies --role-name aura-ledger-ec2-role --query 'AttachedPolicies[].PolicyArn' --output text

# --- 4.1 State bucket ----------------------------------------------------------
echo "== 4.1 State bucket: $BUCKET"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "Bucket already exists, re-applying settings"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
fi
# Versioning: roll back to an earlier state file if an apply ever corrupts it
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
# State can contain resource details, so refuse any non-TLS access
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://tfstate-bucket-policy.json
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=Project,Value=AuraDigitalBank},{Key=Purpose,Value=terraform-state},{Key=ManagedBy,Value=bootstrap}]'
echo "Bucket configured"

# --- 4.2 GitHub OIDC provider --------------------------------------------------
echo "== 4.2 OIDC provider"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "OIDC provider already exists"
else
  aws iam create-open-id-connect-provider --url "https://${OIDC_HOST}" \
    --client-id-list sts.amazonaws.com \
    --tags Key=Project,Value=AuraDigitalBank Key=ManagedBy,Value=bootstrap >/dev/null
  echo "OIDC provider created"
fi

# Create a role, or update its trust policy and session length if it exists
ensure_role() {
  local name=$1 trust=$2 duration=$3 description=$4
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$name" --policy-document "file://${trust}"
    aws iam update-role --role-name "$name" --max-session-duration "$duration" --description "$description"
    echo "Role $name updated"
  else
    aws iam create-role --role-name "$name" --assume-role-policy-document "file://${trust}" \
      --max-session-duration "$duration" --description "$description" \
      --tags Key=Project,Value=AuraDigitalBank Key=ManagedBy,Value=bootstrap >/dev/null
    echo "Role $name created"
  fi
}

# --- 4.3 Plan role: pull requests only, read-only ------------------------------
echo "== 4.3 Plan role"
ensure_role aura-github-plan github-plan-trust.json 3600 \
  "GitHub Actions terraform plan on pull requests (read-only)"
aws iam attach-role-policy --role-name aura-github-plan \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
aws iam put-role-policy --role-name aura-github-plan --policy-name terraform-plan-state \
  --policy-document file://plan-role-policy.json

# --- 4.4 Apply role: production environment only, scoped writes ---------------
echo "== 4.4 Apply role"
# 2-hour sessions: a Multi-AZ RDS restore can outlast the 1-hour default
ensure_role aura-github-apply github-apply-trust.json 7200 \
  "GitHub Actions terraform apply from the production environment on main"
aws iam attach-role-policy --role-name aura-github-apply \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
aws iam put-role-policy --role-name aura-github-apply --policy-name terraform-apply-scoped \
  --policy-document file://apply-role-policy.json

# --- 4.5 Prove the boundaries with the IAM policy simulator --------------------
echo "== 4.5 Policy simulation (every line should say PASS)"
check() {
  local role=$1 action=$2 resource=$3 expected=$4; shift 4
  local got mark=PASS
  got=$(aws iam simulate-principal-policy \
    --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:role/${role}" \
    --action-names "$action" --resource-arns "$resource" "$@" \
    --query 'EvaluationResults[0].EvalDecision' --output text)
  [ "$got" = "$expected" ] || mark=FAIL
  printf '%-4s  %-17s  %-24s  %-13s  %s\n' "$mark" "$role" "$action" "$got" "$resource"
}
IN_REGION=(--context-entries "ContextKeyName=aws:RequestedRegion,ContextKeyValues=ca-central-1,ContextKeyType=string")
OUT_REGION=(--context-entries "ContextKeyName=aws:RequestedRegion,ContextKeyValues=us-east-1,ContextKeyType=string")
TO_EC2=(--context-entries "ContextKeyName=iam:PassedToService,ContextKeyValues=ec2.amazonaws.com,ContextKeyType=string")
STATE="arn:aws:s3:::${BUCKET}/prod/terraform.tfstate"
COMPLIANCE_OBJ="arn:aws:s3:::aura-compliance-ak-seng4620-x7k2/test-object"
P="arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter"
R="arn:aws:iam::${ACCOUNT_ID}:role"

check aura-github-plan  s3:GetObject     "$STATE"                    allowed
check aura-github-plan  s3:PutObject     "$STATE"                    implicitDeny
check aura-github-plan  s3:PutObject     "${STATE}.tflock"           allowed
check aura-github-plan  s3:GetObject     "$COMPLIANCE_OBJ"           explicitDeny
check aura-github-plan  ec2:CreateVpc    "*"                         implicitDeny "${IN_REGION[@]}"
check aura-github-apply s3:PutObject     "$STATE"                    allowed
check aura-github-apply s3:GetObject     "$COMPLIANCE_OBJ"           explicitDeny
check aura-github-apply ec2:CreateVpc    "*"                         allowed      "${IN_REGION[@]}"
check aura-github-apply ec2:CreateVpc    "*"                         implicitDeny "${OUT_REGION[@]}"
check aura-github-apply ssm:PutParameter "${P}/aura/dev/db_host"     allowed
check aura-github-apply ssm:PutParameter "${P}/other/test"           implicitDeny
check aura-github-apply iam:PassRole     "${R}/aura-ledger-ec2-role" allowed      "${TO_EC2[@]}"
check aura-github-apply iam:PassRole     "${R}/aura-github-apply"    implicitDeny "${TO_EC2[@]}"
check aura-github-apply iam:DeleteRole   "${R}/aura-ledger-ec2-role" implicitDeny

echo "Bootstrap complete."
