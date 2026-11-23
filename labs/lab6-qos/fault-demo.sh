#!/usr/bin/env bash
# 검사 스크립트가 고장을 잡는지 시험함 (강사 고장 연습용으로도 씀)
# 고장을 하나 내고 check.sh 를 돌린 뒤 바로 되돌림. 마지막에 모두 통과하는지 확인함
#
# 사용
#   ./fault-demo.sh      1 ~ 5번을 차례로 냄 (약 2분, 강사 PC 실측 124 ~ 134초)
#   ./fault-demo.sh 5    5번만 냄 (약 30 ~ 50초)
#
# 4번과 5번은 "편법"임. 통신도 되고 숫자도 그럴듯하지만 의도한 QoS가 아님
cd "$(dirname "$0")"
P=clab-lab6
WANT="${1:-all}"

r1()   { docker exec "$P-r1" "$@"; }
# 되돌리기: 표시 규칙과 줄을 처음부터 다시 검. 무엇이 망가졌든 같은 자리로 돌아옴
undo() { r1 sh /root/mark.sh >/dev/null; r1 sh /root/shape.sh on >/dev/null; sleep 8; }
want() { [ "$WANT" = all ] || [ "$WANT" = "$1" ]; }

# 고장은 "제대로 동작하는 상태"를 망가뜨리는 것임. 그래서 먼저 그 상태로 맞춰 둠
# (이미 망가진 자리에서 시작하면 무엇 때문에 실패했는지 말할 수 없음)
echo "##### 먼저 처음 상태(QoS 켬)로 맞춥니다"
undo

if [ "$WANT" = all ]; then
  echo "##### 정상 상태"; ./check.sh; echo
fi

if want 1; then
echo "##### 고장1: 들어오는 쪽 표시 규칙을 지움 (DSCP를 아무도 안 적음)"
r1 tc qdisc del dev eth1 clsact
r1 tc qdisc del dev eth2 clsact
./check.sh; undo; echo
fi

if want 2; then
echo "##### 고장2: 줄을 다시 하나로 되돌림 (QoS를 꺼 버림)"
r1 sh /root/shape.sh off
./check.sh; undo; echo
fi

if want 3; then
echo "##### 고장3: 중요 줄의 보장 대역을 5Mbit 대신 1Mbit로 적음"
r1 tc class change dev eth3 parent 1:1 classid 1:10 htb rate 1mbit ceil 10mbit prio 1 quantum 1514
./check.sh; undo; echo
fi

if want 4; then
echo "##### 고장4(편법): 줄은 안 만들고 대량 쪽 보내는 속도만 낮춤"
echo "        먼저 '얌전한 대량 트래픽'으로 재 봄. 숫자는 통과처럼 보임"
r1 sh /root/shape.sh off >/dev/null
TMP=$(mktemp)
docker exec $P-h1 iperf3 -c 10.60.3.10 -p 5201 -u -b 5M -l 1200 -t 8 -J > "$TMP" 2>&1 &
sleep 1
docker exec $P-h2 iperf3 -c 10.60.3.10 -p 5202 -u -b 4M -l 1200 -t 8 -J > /dev/null 2>&1 &
wait
echo "        -> 중요 흐름 받은 속도: $(jq -r '((.end.sum.bits_per_second//0)/1000000)*((100-(.end.sum.lost_percent//100))/100)|.*100|round/100' "$TMP") Mbit/s" \
     ", 잃은 비율 $(jq -r '.end.sum.lost_percent//"?"' "$TMP") %"
echo "        보내는 쪽이 얌전해서 안 막힌 것이지, 막혔을 때 지켜 주는 장치가 있는 것이 아님"
rm -f "$TMP"
./check.sh; undo; echo
fi

if want 5; then
echo "##### 고장5(편법): 표시를 지우고 출발지 주소로 줄을 세움"
echo "        중요 흐름은 5Mbit/s를 그대로 받고 중요 줄에 패킷도 들어감. 그래도 의도한 QoS는 아님"
r1 tc qdisc del dev eth1 clsact
r1 tc filter add dev eth3 parent 1: protocol ip prio 3 u32 \
   match ip src 10.60.1.10/32 flowid 1:10
./check.sh; undo; echo
fi

echo "##### 되돌린 뒤 확인"; ./check.sh
