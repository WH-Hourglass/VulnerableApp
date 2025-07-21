#!/bin/bash
# 실행 시간 측정 시작
START_TIME=$(date +%s)

# ⛳ 인자 처리
webapp_CONTAINER="${1:-containername}" # webgoat, vulnapp
ZAP_PORT="${2:-8090}"
START_PATH="${3:-/}"  # ex: /webgoat/start.mvc
WEBAPP_HOST_PORT="${4:-8081}" # zap에 넘겨줄 외부포트 변수
ZAP_HOST="127.0.0.1"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_JSON="$HOME/zap_${webapp_CONTAINER}.json"
HOST="http://127.0.0.1:${WEBAPP_HOST_PORT}"
TARGET_URL="${HOST}${START_PATH}"

echo "[*] ZAP 스캔 대상: $TARGET_URL"

# 경로 파일 정의 ($ 제거)
PATH_FILE="${WORKSPACE}/components/scripts/path.txt"

# 경로 파일 존재 확인
if [ ! -f "$PATH_FILE" ]; then
    echo "❌ 경로 파일을 찾을 수 없습니다: $PATH_FILE"
    exit 1
fi

### [2] 모든 URL을 ZAP에 등록 ###
echo "[2] ZAP에 URL 등록 중..."
URL_COUNT=0
while IFS= read -r path || [[ -n "$path" ]]; do
    # 빈 줄이나 주석 건너뛰기
    [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
    
    # 슬래시 정규화
    [[ "$path" != /* ]] && path="/$path"
    
    url="${HOST}${path}"
    echo "   → $url"
    
    # URL 접근 등록
    curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/core/action/accessUrl/?url=$(printf '%s' "$url" | jq -sRr @uri)&followRedirects=true" > /dev/null
    ((URL_COUNT++))
    
done < "$PATH_FILE"
echo "✅ 총 ${URL_COUNT}개 URL 등록 완료"

### [3] Spider 스캔 실행 ###
echo "[3] Spider 스캔 시작..."
SPIDER_ID=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/spider/action/scan/?url=$(printf '%s' "$TARGET_URL" | jq -sRr @uri)" | jq -r '.scan')
echo "   Spider ID: $SPIDER_ID"

while true; do
    STATUS=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/spider/view/status/?scanId=$SPIDER_ID" | jq -r '.status')
    echo "   Spider 진행률: $STATUS%"
    [ "$STATUS" == "100" ] && break
    sleep 2
done
echo "✅ Spider 스캔 완료"

### [4] 각 경로별 Passive 스캔 ###
echo "[4] 각 경로별 Passive 스캔 시작..."
PASSIVE_COUNT=0
while IFS= read -r path || [[ -n "$path" ]]; do
    # 빈 줄이나 주석 건너뛰기
    [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
    
    # 슬래시 정규화
    [[ "$path" != /* ]] && path="/$path"
    
    url="${HOST}${path}"
    ((PASSIVE_COUNT++))
    
    echo "   [$PASSIVE_COUNT] $url Passive 스캔 중..."
    
    # 해당 URL에 추가 접근하여 Passive 스캔 데이터 생성
    curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/core/action/accessUrl/?url=$(printf '%s' "$url" | jq -sRr @uri)&followRedirects=true" > /dev/null
    
    # 잠시 대기하여 Passive 스캔이 처리되도록 함
    sleep 1
    
done < "$PATH_FILE"

# 모든 Passive 스캔 완료 대기
echo "[4-1] 전체 Passive 스캔 완료 대기..."
while true; do
    RECORDS=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/pscan/view/recordsToScan/" | jq -r '.recordsToScan')
    echo "   남은 레코드: $RECORDS"
    [ "$RECORDS" -eq 0 ] && break
    sleep 2
done
echo "✅ 모든 Passive 스캔 완료 (총 ${PASSIVE_COUNT}개 경로)"

### [5] 각 경로별 Active 스캔 ###
echo "[5] Active 스캔 시작..."
SCAN_COUNT=0
while IFS= read -r path || [[ -n "$path" ]]; do
    # 빈 줄이나 주석 건너뛰기
    [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
    
    # 슬래시 정규화
    [[ "$path" != /* ]] && path="/$path"
    
    url="${HOST}${path}"
    ((SCAN_COUNT++))
    
    echo "   [$SCAN_COUNT] $url 스캔 중..."
    
    ASCAN_ID=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/ascan/action/scan/?url=$(printf '%s' "$url" | jq -sRr @uri)" | jq -r '.scan')
    
    while true; do
        STATUS=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/ascan/view/status/?scanId=$ASCAN_ID" | jq -r '.status')
        echo "      Active 진행률: $STATUS%"
        [ "$STATUS" == "100" ] && break
        sleep 3
    done
    echo "   ✅ $url 스캔 완료"
    
done < "$PATH_FILE"
echo "✅ 모든 Active 스캔 완료 (총 ${SCAN_COUNT}개)"

# JSON 리포트 저장
echo "[4] JSON 리포트 저장..."
curl -s "http://$ZAP_HOST:$ZAP_PORT/OTHER/core/other/jsonreport/" -o "$REPORT_JSON"
if [ -s "$REPORT_JSON" ]; then
  echo "[+] 리포트: $REPORT_JSON"
else
  echo "[-] 리포트 생성 실패"
  exit 1
fi

# 종료 및 수행 시간 출력
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
printf "[+] 전체 수행 시간: %d분 %d초\n" $((ELAPSED/60)) $((ELAPSED%60))
