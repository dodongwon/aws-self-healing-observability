#!/usr/bin/env bash
# 앱 Lambda 코드 배포: 새 버전 게시 → 해당 버전 스모크 테스트 → 통과 시 live 별칭 전환 + last-known-good 기록
# 스모크 테스트 실패 시 별칭을 건드리지 않으므로 기존 버전이 계속 서비스된다 (fail-safe).
#
# 사용법: scripts/deploy_app.sh <function-name> <alias-name> <ssm-param-name>
set -euo pipefail

FUNCTION=$1
ALIAS=$2
PARAM=$3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Packaging src/app"
(cd "$ROOT/src/app" && zip -qr "$WORK/app.zip" . -x '__pycache__/*')

echo "==> Waiting for pending function updates"
aws lambda wait function-updated-v2 --function-name "$FUNCTION"

echo "==> Uploading code and publishing a new version"
aws lambda update-function-code --function-name "$FUNCTION" --zip-file "fileb://$WORK/app.zip" >/dev/null
aws lambda wait function-updated-v2 --function-name "$FUNCTION"
VERSION=$(aws lambda publish-version --function-name "$FUNCTION" --query Version --output text)
echo "    published version: $VERSION"

echo "==> Smoke test on version $VERSION (before switching traffic)"
cat >"$WORK/event.json" <<'EOF'
{"version":"2.0","routeKey":"GET /health","rawPath":"/health","rawQueryString":"","headers":{},
 "requestContext":{"http":{"method":"GET","path":"/health","sourceIp":"127.0.0.1"},"requestId":"smoke-test","stage":"$default"},
 "isBase64Encoded":false}
EOF
aws lambda invoke --function-name "$FUNCTION" --qualifier "$VERSION" \
  --cli-binary-format raw-in-base64-out --payload "file://$WORK/event.json" "$WORK/out.json" >"$WORK/meta.json"

STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("statusCode"))' "$WORK/out.json")
FUNC_ERROR=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("FunctionError",""))' "$WORK/meta.json")
if [[ "$STATUS" != "200" || -n "$FUNC_ERROR" ]]; then
  echo "!! Smoke test failed (status=$STATUS error=$FUNC_ERROR). Alias NOT switched."
  cat "$WORK/out.json"
  exit 1
fi
echo "    smoke test passed"

PREVIOUS=$(aws lambda get-alias --function-name "$FUNCTION" --name "$ALIAS" --query FunctionVersion --output text)
echo "==> Switching alias '$ALIAS': $PREVIOUS -> $VERSION"
aws lambda update-alias --function-name "$FUNCTION" --name "$ALIAS" --function-version "$VERSION" \
  --description "deployed by CI" >/dev/null
aws ssm put-parameter --name "$PARAM" --value "$VERSION" --type String --overwrite >/dev/null
echo "==> Done. last-known-good = $VERSION"
