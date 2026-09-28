#!/usr/bin/env bash
# 데모용 부하 생성: POST /items 와 GET /items/{id} 를 번갈아 호출한다.
# 비용 보호를 위해 총 요청 수는 MAX_REQUESTS 를 넘지 않는다. (macOS 기본 bash 3.2 호환)
#
# 사용법: scripts/load.sh <api-endpoint> [duration-seconds=600] [rps=2]
set -uo pipefail

ENDPOINT=${1:?api endpoint required}
DURATION=${2:-600}
RPS=${3:-2}
MAX_REQUESTS=3000

INTERVAL=$(python3 -c "print(1/$RPS)")
BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT
END=$((SECONDS + DURATION))
TOTAL=0 OK=0 C4XX=0 C5XX=0 OTHER=0
LAST_ID=""

summary() { echo "[load] $1: total=$TOTAL 2xx=$OK 4xx=$C4XX 5xx=$C5XX other=$OTHER"; }

while (( SECONDS < END && TOTAL < MAX_REQUESTS )); do
  if (( TOTAL % 2 == 0 )) || [[ -z "$LAST_ID" ]]; then
    CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$ENDPOINT/items" \
      -H 'content-type: application/json' -d "{\"payload\":{\"n\":$TOTAL}}")
    if [[ "$CODE" == "201" ]]; then
      LAST_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$BODY")
    fi
  else
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "$ENDPOINT/items/$LAST_ID")
  fi

  case "$CODE" in
    2*) OK=$((OK + 1)) ;;
    4*) C4XX=$((C4XX + 1)) ;;
    5*) C5XX=$((C5XX + 1)) ;;
    *) OTHER=$((OTHER + 1)) ;;
  esac
  TOTAL=$((TOTAL + 1))
  (( TOTAL % 100 == 0 )) && summary "progress"
  sleep "$INTERVAL"
done

summary "finished"
