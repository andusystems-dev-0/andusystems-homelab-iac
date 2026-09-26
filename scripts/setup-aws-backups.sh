#!/usr/bin/env bash
# One-time setup of the Pterodactyl backup target on AWS + the GitHub Actions secrets.
# Prereqs: authenticated `aws` (run your normal `aws login` first) and `gh` (repo access).
#
#   scripts/setup-aws-backups.sh
#
# Creates: the S3 bucket (block-public-access + SSE-S3 + abort-incomplete-multipart),
# a least-privilege IAM user/policy scoped to that bucket, an access key, and sets the
# repo secrets AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION / S3_BUCKET.
set -euo pipefail

S3_BUCKET="${S3_BUCKET:-andusystems-pterodactyl-backups}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
IAM_USER="${IAM_USER:-pterodactyl-backup}"
IAM_POLICY="${IAM_POLICY:-pterodactyl-backup-s3}"
REPO="${REPO:-andusystems-dev-0/andusystems-homelab-iac}"

aws sts get-caller-identity >/dev/null || { echo "AWS not authenticated — run your 'aws login' first" >&2; exit 1; }
ACCT="$(aws sts get-caller-identity --query Account --output text)"
echo "account=$ACCT region=$AWS_REGION bucket=$S3_BUCKET"

# --- bucket ------------------------------------------------------------------
if aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
  echo "bucket exists"
else
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  fi
  echo "bucket created"
fi
aws s3api put-public-access-block --bucket "$S3_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$S3_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-lifecycle-configuration --bucket "$S3_BUCKET" --lifecycle-configuration '{
  "Rules":[{"ID":"abort-incomplete-multipart","Status":"Enabled","Filter":{},
            "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'
echo "bucket hardened (block-public, SSE-S3, abort-incomplete-multipart)"

# --- least-privilege IAM policy + user + key ---------------------------------
POLICY_DOC="$(cat <<JSON
{"Version":"2012-10-17","Statement":[
  {"Sid":"List","Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":"arn:aws:s3:::${S3_BUCKET}"},
  {"Sid":"RW","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::${S3_BUCKET}/*"}
]}
JSON
)"
POLICY_ARN="arn:aws:iam::${ACCT}:policy/${IAM_POLICY}"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  VID="$(aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "$POLICY_DOC" --set-as-default --query PolicyVersion.VersionId --output text)"
  echo "policy updated ($VID)"
else
  aws iam create-policy --policy-name "$IAM_POLICY" --policy-document "$POLICY_DOC" >/dev/null
  echo "policy created"
fi
aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1 || { aws iam create-user --user-name "$IAM_USER" >/dev/null; echo "user created"; }
aws iam attach-user-policy --user-name "$IAM_USER" --policy-arn "$POLICY_ARN"

# rotate: drop existing keys so we can mint a fresh one non-interactively
for k in $(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$k"
done
CREDS_JSON="$(aws iam create-access-key --user-name "$IAM_USER" --output json)"
AKID="$(echo "$CREDS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
SAK="$(echo "$CREDS_JSON"  | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

# --- GitHub Actions secrets (values never printed) ---------------------------
gh secret set AWS_ACCESS_KEY_ID     --repo "$REPO" --body "$AKID"
gh secret set AWS_SECRET_ACCESS_KEY --repo "$REPO" --body "$SAK"
gh secret set AWS_DEFAULT_REGION    --repo "$REPO" --body "$AWS_REGION"
gh secret set S3_BUCKET             --repo "$REPO" --body "$S3_BUCKET"
echo "GHA secrets set: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION, S3_BUCKET"
echo "DONE. IAM user=${IAM_USER} (key ${AKID:0:6}…), bucket=s3://${S3_BUCKET} in ${AWS_REGION}"
