#!/bin/bash
# Songitude serverless publish backend — creates a NEW, isolated bucket + two Lambdas.
# 100% additive: it never touches the songitude.com site bucket or any existing resource.
#
# Fill these in (or pass as env vars) before running:
#   GOOGLE_CLIENT_ID  – your Google OAuth Web client id (…apps.googleusercontent.com)
#   ALLOWED_EMAILS    – comma-separated Google accounts allowed to publish
# Then:  bash deploy.sh
set -euo pipefail

REGION="${REGION:-us-east-1}"
BUCKET="${BUCKET:-songitude-walks}"
ROLE="${ROLE:-songitude-walks-lambda}"
PRESIGN_FN="${PRESIGN_FN:-songitude-presign}"
MANIFEST_FN="${MANIFEST_FN:-songitude-manifest}"
ALLOW_ORIGIN="${ALLOW_ORIGIN:-https://songitude.com}"
PUBLIC_BASE="${PUBLIC_BASE:-https://${BUCKET}.s3.amazonaws.com}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:?set GOOGLE_CLIENT_ID}"
ALLOWED_EMAILS="${ALLOWED_EMAILS:?set ALLOWED_EMAILS}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> Bucket s3://$BUCKET ($REGION)"
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"

echo "==> Public-access block (allow a public read policy; keep ACLs off)"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false

echo "==> Bucket policy: public GET on walks/* only"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[{\"Sid\":\"PublicReadWalks\",\"Effect\":\"Allow\",\"Principal\":\"*\",
    \"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/walks/*\"}]
}"

echo "==> CORS (GET/HEAD for players, PUT for presigned upload from the editor)"
aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration "{
  \"CORSRules\":[{
    \"AllowedOrigins\":[\"$ALLOW_ORIGIN\",\"http://localhost:8000\",\"http://localhost:5173\"],
    \"AllowedMethods\":[\"GET\",\"HEAD\",\"PUT\"],
    \"AllowedHeaders\":[\"*\"],\"ExposeHeaders\":[\"ETag\"],\"MaxAgeSeconds\":3000
  }]
}"

echo "==> IAM role $ROLE"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow",
      "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name inline --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:ListBucket\"],
     \"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],
     \"Resource\":\"arn:aws:logs:*:*:*\"}]}"
ROLE_ARN="arn:aws:iam::${ACCT}:role/${ROLE}"
echo "    role propagation…"; sleep 12

deploy_fn () {  # name dir handlerEnv timeout
  local name="$1" dir="$2" env="$3" timeout="$4"
  ( cd "$HERE/$dir" && zip -qr /tmp/$name.zip index.mjs )
  if aws lambda get-function --function-name "$name" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$name" --zip-file "fileb:///tmp/$name.zip" >/dev/null
    aws lambda wait function-updated --function-name "$name"
    aws lambda update-function-configuration --function-name "$name" \
      --environment "Variables={$env}" --timeout "$timeout" >/dev/null
  else
    aws lambda create-function --function-name "$name" --runtime nodejs20.x --role "$ROLE_ARN" \
      --handler index.handler --zip-file "fileb:///tmp/$name.zip" \
      --environment "Variables={$env}" --timeout "$timeout" --memory-size 256 >/dev/null
  fi
}

echo "==> Presign Lambda"
deploy_fn "$PRESIGN_FN" presign \
  "WALKS_BUCKET=$BUCKET,GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID,ALLOWED_EMAILS=$ALLOWED_EMAILS,ALLOW_ORIGIN=$ALLOW_ORIGIN" 15

# Function URL (public; auth is enforced inside via the Google token)
CORS_JSON="{\"AllowOrigins\":[\"$ALLOW_ORIGIN\",\"http://localhost:8000\",\"http://localhost:5173\"],\"AllowMethods\":[\"POST\"],\"AllowHeaders\":[\"authorization\",\"content-type\"],\"MaxAge\":3000}"
aws lambda create-function-url-config --function-name "$PRESIGN_FN" --auth-type NONE --cors "$CORS_JSON" >/dev/null 2>&1 \
  || aws lambda update-function-url-config --function-name "$PRESIGN_FN" --auth-type NONE --cors "$CORS_JSON" >/dev/null 2>&1 || true
aws lambda add-permission --function-name "$PRESIGN_FN" --statement-id fnurl \
  --action lambda:InvokeFunctionUrl --principal "*" --function-url-auth-type NONE >/dev/null 2>&1 || true
FN_URL="$(aws lambda get-function-url-config --function-name "$PRESIGN_FN" --query FunctionUrl --output text)"

echo "==> Manifest Lambda"
deploy_fn "$MANIFEST_FN" manifest "WALKS_BUCKET=$BUCKET,PUBLIC_BASE=$PUBLIC_BASE" 60
aws lambda add-permission --function-name "$MANIFEST_FN" --statement-id s3invoke \
  --action lambda:InvokeFunction --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$BUCKET" >/dev/null 2>&1 || true
MANIFEST_ARN="$(aws lambda get-function --function-name "$MANIFEST_FN" --query Configuration.FunctionArn --output text)"

echo "==> S3 trigger: walks/*/bundle.zip -> manifest"
aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration "{
  \"LambdaFunctionConfigurations\":[{
    \"LambdaFunctionArn\":\"$MANIFEST_ARN\",\"Events\":[\"s3:ObjectCreated:*\"],
    \"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"suffix\",\"Value\":\"bundle.zip\"}]}}}]}"

echo
echo "DONE."
echo "  Publish API (put in editor/config.js publishApiUrl): $FN_URL"
echo "  Manifest URL (put in the iOS app):                  $PUBLIC_BASE/walks/manifest.json"
