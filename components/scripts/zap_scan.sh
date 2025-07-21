#!/bin/bash

# 실행 시간 측정 시작
START_TIME=$(date +%s)

# ⛳ 인자 처리
CONTAINER_NAME="${1:-containername}"    # 컨테이너명
ZAP_PORT="${2:-8090}"                   # ZAP 데몬 포트
PATH_FILE="${3:-paths.txt}"             # URL 경로 리스트 파일
WEBAPP_PORT="${4:-8080}"                # 웹앱 내부 포트

# 설정 변수
ZAP_API="http://localhost:${ZAP_PORT}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_JSON="$HOME/zap_report_${TIMESTAMP}.json"

echo "[*] ZAP 경로별 스캔 시작..."
echo "    컨테이너: $CONTAINER_NAME"
echo "    ZAP 포트: $ZAP_PORT"
echo "    경로 파일: $PATH_FILE"

### [1] 사전 검증 ###
# ZAP 데몬 연결 확인
if ! curl -s "$ZAP_API/JSON/core/view/version/" > /dev/null; then
    echo "❌ ZAP 데몬 연결 실패 (포트: $ZAP_PORT)"
    echo "   ZAP 데몬이 실행 중인지 확인하세요."
    exit 1
fi

# 경로 파일 존재 확인
if [ ! -f "$PATH_FILE" ]; then
    echo "❌ 경로 파일을 찾을 수 없습니다: $PATH_FILE"
    exit 1
fi

# 컨테이너 IP 확인
CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
if [ -z "$CONTAINER_IP" ]; then
    echo "❌ 컨테이너 IP 조회 실패: $CONTAINER_NAME"
    echo "   docker ps로 컨테이너 상태를 확인하세요."
    exit 1
fi

TARGET_HOST="http://${CONTAINER_IP}:${WEBAPP_PORT}"
echo "✅ 대상 호스트: $TARGET_HOST"

### [2] 모든 URL을 ZAP에 등록 ###
echo "[2] ZAP에 URL 등록 중..."
URL_COUNT=0
while IFS= read -r path || [[ -n "$path" ]]; do
    # 빈 줄이나 주석 건너뛰기
    [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
    
    # 슬래시 정규화
    [[ "$path" != /* ]] && path="/$path"
    
    url="${TARGET_HOST}${path}"
    echo "   → $url"
    
    # URL 접근 등록
    curl -s "$ZAP_API/JSON/core/action/accessUrl/?url=$(printf '%s' "$url" | jq -sRr @uri)&followRedirects=true" > /dev/null
    ((URL_COUNT++))
    
done < "$PATH_FILE"

echo "✅ 총 ${URL_COUNT}개 URL 등록 완료"

### [3] Spider 스캔 실행 ###
echo "[3] Spider 스캔 시작..."
FIRST_PATH=$(grep -v '^[[:space:]]*#' "$PATH_FILE" | grep -v '^[[:space:]]*$' | head -n 1)
[[ "$FIRST_PATH" != /* ]] && FIRST_PATH="/$FIRST_PATH"
MAIN_URL="${TARGET_HOST}${FIRST_PATH}"

SPIDER_ID=$(curl -s "$ZAP_API/JSON/spider/action/scan/?url=$(printf '%s' "$MAIN_URL" | jq -sRr @uri)" | jq -r '.scan')
echo "   Spider ID: $SPIDER_ID"

while true; do
    STATUS=$(curl -s "$ZAP_API/JSON/spider/view/status/?scanId=$SPIDER_ID" | jq -r '.status')
    echo "   Spider 진행률: $STATUS%"
    [ "$STATUS" == "100" ] && break
    sleep 2
done
echo "✅ Spider 스캔 완료"

### [4] Passive 스캔 대기 ###
echo "[4] Passive 스캔 대기 중..."
while true; do
    RECORDS=$(curl -s "$ZAP_API/JSON/pscan/view/recordsToScan/" | jq -r '.recordsToScan')
    echo "   남은 레코드: $RECORDS"
    [ "$RECORDS" -eq 0 ] && break
    sleep 2
done
echo "✅ Passive 스캔 완료"

### [5] 각 경로별 Active 스캔 ###
echo "[5] Active 스캔 시작..."
SCAN_COUNT=0

while IFS= read -r path || [[ -n "$path" ]]; do
    # 빈 줄이나 주석 건너뛰기
    [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
    
    # 슬래시 정규화
    [[ "$path" != /* ]] && path="/$path"
    
    url="${TARGET_HOST}${path}"
    ((SCAN_COUNT++))
    
    echo "   [$SCAN_COUNT] $url 스캔 중..."
    
    ASCAN_ID=$(curl -s "$ZAP_API/JSON/ascan/action/scan/?url=$(printf '%s' "$url" | jq -sRr @uri)" | jq -r '.scan')
    
    while true; do
        STATUS=$(curl -s "$ZAP_API/JSON/ascan/view/status/?scanId=$ASCAN_ID" | jq -r '.status')
        echo "      Active 진행률: $STATUS%"
        [ "$STATUS" == "100" ] && break
        sleep 3
    done
    echo "   ✅ $url 스캔 완료"
    
done < "$PATH_FILE"

echo "✅ 모든 Active 스캔 완료 (총 ${SCAN_COUNT}개)"

### [6] 리포트 생성 ###
echo "[6] 리포트 생성 중..."

# JSON 리포트 저장
curl -s "$ZAP_API/OTHER/core/other/jsonreport/" -o "$REPORT_JSON"
if [ -s "$REPORT_JSON" ]; then
    echo "✅ JSON 리포트: $REPORT_JSON"
else
    echo "❌ JSON 리포트 생성 실패"
fi

### [7] 완료 및 통계 ###
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "🎉 스캔 완료!"
echo "   📊 스캔 통계:"
echo "      - 대상 URL: ${URL_COUNT}개"
echo "      - Active 스캔: ${SCAN_COUNT}개"
echo "      - 소요 시간: $((ELAPSED/60))분 $((ELAPSED%60))초"
echo "   📁 리포트 파일:"
echo "      - JSON: $REPORT_JSON"
