#!/usr/bin/env bash
# 자가복구 인수 테스트 (시스템 분석·설계서 7.2)
#   1) FAULT_RATE 를 넣은 결함 버전을 게시하고 live 별칭을 전환한다 (스모크 테스트를 일부러 건너뜀)
#   2) 부하를 걸면서 알람 발생 시각과 자동 롤백 시각을 기록한다
#   3) MTTD(탐지) / MTTR(복구) 를 출력한다
# last-known-good 파라미터는 건드리지 않으므로 복구 Lambda는 직전 정상 버전으로 되돌린다.
#
# 사용법: scripts/chaos.sh [fault-rate=0.5] [timeout-seconds=1500]
set -euo pipefail

FAULT_RATE=${1:-0.5}
TIMEOUT=${2:-1500}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tf_out() { terraform -chdir="$ROOT/infra/envs/dev" output -raw "$1"; }

ENDPOINT=$(tf_out api_endpoint)
FUNCTION=$(tf_out function_name)
ALIAS=$(tf_out alias_name)
ALARM=$(tf_out error_rate_alarm_name)

now() { date -u +%s; }
ts() { date -u -r "$1" +%H:%M:%S 2>/dev/null || date -u -d "@$1" +%H:%M:%S; }

set_fault_rate() {
  local vars
  vars=$(aws lambda get-function-configuration --function-name "$FUNCTION" --query Environment.Variables --output json |
    python3 -c 'import json,sys; v=json.load(sys.stdin); v["FAULT_RATE"]=sys.argv[1]; print(json.dumps({"Variables": v}))' "$1")
  aws lambda update-function-configuration --function-name "$FUNCTION" --environment "$vars" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FUNCTION"
}

GOOD=$(aws lambda get-alias --function-name "$FUNCTION" --name "$ALIAS" --query FunctionVersion --output text)
echo "==> Current live version (known good): $GOOD"

echo "==> Publishing faulty version (FAULT_RATE=$FAULT_RATE)"
set_fault_rate "$FAULT_RATE"
BAD=$(aws lambda publish-version --function-name "$FUNCTION" --description "chaos FAULT_RATE=$FAULT_RATE" --query Version --output text)
# $LATEST 는 즉시 원복 — 다음 CI 배포에 결함 설정이 섞이지 않도록
set_fault_rate "0"

aws lambda update-alias --function-name "$FUNCTION" --name "$ALIAS" --function-version "$BAD" --description "chaos test" >/dev/null
T_DEPLOY=$(now)
echo "==> [$(ts "$T_DEPLOY")] live -> v$BAD (faulty). Starting load..."

"$ROOT/scripts/load.sh" "$ENDPOINT" "$TIMEOUT" 2 &
LOAD_PID=$!
trap 'kill $LOAD_PID 2>/dev/null || true' EXIT

T_ALARM="" T_ROLLBACK=""
while (( $(now) - T_DEPLOY < TIMEOUT )); do
  sleep 15
  if [[ -z "$T_ALARM" ]]; then
    STATE=$(aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text)
    if [[ "$STATE" == "ALARM" ]]; then
      T_ALARM=$(now)
      echo "==> [$(ts "$T_ALARM")] Alarm $ALARM -> ALARM"
    fi
  fi
  CURRENT=$(aws lambda get-alias --function-name "$FUNCTION" --name "$ALIAS" --query FunctionVersion --output text)
  if [[ "$CURRENT" != "$BAD" ]]; then
    T_ROLLBACK=$(now)
    echo "==> [$(ts "$T_ROLLBACK")] live rolled back: v$BAD -> v$CURRENT"
    break
  fi
done

kill $LOAD_PID 2>/dev/null || true
wait $LOAD_PID 2>/dev/null || true

if [[ -n "$T_ROLLBACK" ]]; then
  echo "==> Verifying recovery: 60s of load on the rolled-back version (expect 5xx=0)"
  "$ROOT/scripts/load.sh" "$ENDPOINT" 60 2 | tail -1
fi

echo
echo "================ Chaos test result ================"
echo "faulty version     : v$BAD (FAULT_RATE=$FAULT_RATE)"
echo "known good version : v$GOOD"
if [[ -n "$T_ROLLBACK" ]]; then
  # 폴링 간격(15초) 오차를 없애기 위해 AWS 기록에서 정확한 시각을 가져온다
  #   알람 시각  : CloudWatch 알람 히스토리의 OK -> ALARM 전환
  #   롤백 시각  : 복구 Lambda 로그의 "Rolled back alias" 이벤트
  SINCE_MS=$((T_DEPLOY * 1000))
  ALARM_AT=$(aws cloudwatch describe-alarm-history --alarm-name "$ALARM" --history-item-type StateUpdate \
    --start-date "$(date -u -r "$T_DEPLOY" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$T_DEPLOY" +%Y-%m-%dT%H:%M:%SZ)" \
    --query "AlarmHistoryItems[?contains(HistorySummary, 'to ALARM')] | [-1].Timestamp" --output text)
  ROLLBACK_MS=$(aws logs filter-log-events --log-group-name "/aws/lambda/${FUNCTION%-api}-remediation" \
    --start-time "$SINCE_MS" --filter-pattern '"Rolled back alias"' --query 'events[].timestamp' --output text | tr '\t' '\n' | grep -m1 '^[0-9]' || true)
  python3 - "$T_DEPLOY" "$ALARM_AT" "$ROLLBACK_MS" <<'PY'
import sys
from datetime import datetime
deploy, alarm_at, rollback_ms = float(sys.argv[1]), sys.argv[2], sys.argv[3]
alarm = datetime.fromisoformat(alarm_at).timestamp() if alarm_at not in ("", "None") else None
rollback = int(rollback_ms) / 1000 if rollback_ms not in ("", "None") else None
if alarm:
    print(f"MTTD (deploy->alarm)    : {alarm - deploy:.1f}s")
if rollback:
    print(f"MTTR (deploy->rollback) : {rollback - deploy:.1f}s")
if alarm and rollback:
    print(f"alarm->rollback         : {rollback - alarm:.1f}s")
PY
  echo "result             : PASS"
else
  echo "result             : FAIL — no rollback within ${TIMEOUT}s. Restore manually:"
  echo "  aws lambda update-alias --function-name $FUNCTION --name $ALIAS --function-version $GOOD"
  exit 1
fi
