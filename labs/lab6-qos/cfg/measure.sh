#!/usr/bin/env bash
# QoS가 정말 일하는지 숫자로 재는 도구 (WSL 쪽에서 실행함, 컨테이너 안이 아님)
#
# 사용법
#   bash cfg/measure.sh off    QoS 없이 혼잡을 만들고 잼
#   bash cfg/measure.sh on     QoS를 켜고 같은 혼잡을 만들고 잼
#   bash cfg/measure.sh ecn    ECN 확인용. 대량 트래픽을 TCP로 보내고 표시 횟수를 셈
#
# 재는 방법
#   중요(h1) : UDP 5Mbit/s 를 보냄. 좁은 구간은 10Mbit/s 이므로 혼자면 다 지나감
#   대량(h2) : UDP 20Mbit/s 를 보냄. 혼자서도 좁은 구간을 넘침
#   둘을 같이 보내면 합이 25Mbit/s 라 혼잡이 생김. 이때 중요 트래픽이 얼마나 받는지를 봄
#   동시에 h1(EF 표시)과 h2(기본 표시)에서 ping을 보내 기다린 시간(왕복 시간)도 비교함
set -u
P=clab-lab6
MODE="${1:-on}"
DUR=20

cd "$(dirname "$0")/.."

case "$MODE" in off|on|ecn) ;; *) echo "사용법: bash cfg/measure.sh [off|on|ecn]" >&2; exit 1;; esac

# 큐를 새로 깔아 세는 값(카운터)을 0에서 시작하게 함
SHAPE=$MODE; [ "$MODE" = ecn ] && SHAPE=on
docker exec $P-r1 sh /root/shape.sh "$SHAPE" >/dev/null
echo "[준비] r1 eth3 큐: $SHAPE, OSPF가 다시 자리 잡을 때까지 5초 기다림"
sleep 5

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 중요 흐름을 먼저 띄움
#   iperf3는 측정 전에 제어용 TCP 연결을 먼저 맺는데,
#   혼잡이 이미 생긴 뒤에 연결하려 하면 그 연결이 1초 가까이 기다리다 실패함
#   (2026-11-23 실측: 대량을 먼저 띄웠더니 중요 흐름이 아예 연결되지 않아 0으로 나옴)
echo "[실행] 중요 = UDP 5Mbit/s 먼저, 1초 뒤 대량, ${DUR}초"
docker exec $P-h1 iperf3 -c 10.60.3.10 -p 5201 -u -b 5M -l 1200 -t $DUR -J    > "$T/ef.json" 2>&1 &
sleep 1
if [ "$MODE" = ecn ]; then
  docker exec $P-h2 iperf3 -c 10.60.3.10 -p 5202 -t $DUR -J                   > "$T/bulk.json" 2>&1 &
else
  docker exec $P-h2 iperf3 -c 10.60.3.10 -p 5202 -u -b 20M -l 1200 -t $DUR -J > "$T/bulk.json" 2>&1 &
fi
sleep 1
docker exec $P-h1 ping -c 15 -i 1 -W 2 10.60.3.10 > "$T/ping-ef.txt"  2>&1 &
docker exec $P-h2 ping -c 15 -i 1 -W 2 10.60.3.10 > "$T/ping-be.txt"  2>&1 &
wait

# iperf3가 적어 주는 bits_per_second 는 "보낸 속도"임.
# UDP는 버려진 것이 있으므로 "받은 속도 = 보낸 속도 x (1 - 잃은 비율)" 로 계산함
# TCP로 잰 경우(.end.sum_sent / .end.sum_received)도 같이 다룸
sent() { jq -r '((.end.sum.bits_per_second // .end.sum_sent.bits_per_second // 0)/1000000)
               | .*100|round/100' "$1" 2>/dev/null; }
recv() { jq -r 'if .end.sum_received then (.end.sum_received.bits_per_second/1000000)
                else ((.end.sum.bits_per_second // 0)/1000000) * ((100-(.end.sum.lost_percent // 0))/100) end
               | .*100|round/100' "$1" 2>/dev/null; }
loss() { jq -r 'if .end.sum.lost_percent then ((.end.sum.lost_percent|.*100|round/100|tostring) + " %")
                else "TCP 재전송 " + ((.end.sum_sent.retransmits // 0)|tostring) + "회" end' "$1" 2>/dev/null; }
rtt()  { grep -o 'min/avg/max[^ ]* = [^ ]*' "$1" | awk -F'= ' '{print $2}'; }

for f in ef bulk; do
  if ! jq -e '.end.sum // .end.sum_received' "$T/$f.json" >/dev/null 2>&1; then
    echo "[경고] $f 흐름의 측정이 실패했습니다. iperf3가 남긴 말:"
    head -5 "$T/$f.json" | sed 's/^/        /'
  fi
done

echo
echo "================ 결과 (모드: $MODE) ================"
FMT="%-16s %10s M %10s M %16s\n"
printf "%-16s %12s %12s %16s\n" "흐름" "보낸속도" "받은속도" "잃은비율"
printf "$FMT" "중요(EF, h1)"   "$(sent "$T/ef.json")"   "$(recv "$T/ef.json")"   "$(loss "$T/ef.json")"
printf "$FMT" "대량(기본, h2)" "$(sent "$T/bulk.json")" "$(recv "$T/bulk.json")" "$(loss "$T/bulk.json")"
echo "왕복 시간 min/avg/max/mdev (ms)"
printf "  중요(EF 표시) : %s\n" "$(rtt "$T/ping-ef.txt")"
printf "  대량(기본 표시): %s\n" "$(rtt "$T/ping-be.txt")"

echo
echo "---- r1 eth3 줄별 통계 (어느 줄로 몇 개가 갔나) ----"
docker exec $P-r1 tc -s class show dev eth3 | grep -A2 "^class htb"
echo
echo "---- r1 eth3 줄 안쪽 큐 (버린 개수, ECN 표시 개수) ----"
docker exec $P-r1 tc -s qdisc show dev eth3
