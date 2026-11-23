#!/usr/bin/env bash
# lab6 검사: "통신이 되는가"가 아니라
#            "DSCP 표시를 보고 중요한 트래픽에 대역을 보장하는가"를 확인함
#
# 사용: ./check.sh
# 한 번 도는 데 약 10초 걸림(강사 PC 실측 10 ~ 11초). 대부분은 혼잡을 직접 만들어 숫자를 재는 시간임
# 검사하는 동안 큐를 새로 깔지 않음. 깔아 버리면 고장이 저절로 고쳐져 못 잡기 때문임
cd "$(dirname "$0")"
P=clab-lab6
fail=0

ok()  { echo "  [통과] $1"; }
bad() { echo "  [실패] $1"; echo "         힌트: $2"; fail=1; }
r1()  { docker exec "$P-r1" "$@" 2>/dev/null; }

# 컨테이너가 떠 있는지부터 봄
for n in r1 r2 h1 h2 h3; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$P-$n"; then
    echo "  [실패] $P-$n 컨테이너가 떠 있지 않음"
    echo "         힌트: ./reset.sh 로 처음 상태로 다시 띄우세요"
    echo; echo "결과: 실패 항목 있음"
    exit 1
  fi
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ----- 먼저 한 번만 읽어 두는 값들 -----
CLASS=$(r1 tc -j -s class show dev eth3)
FLT3=$(r1 tc -j filter show dev eth3)
ING1=$(r1 tc -j filter show dev eth1 ingress)
ING2=$(r1 tc -j filter show dev eth2 ingress)

# 클래스 한 줄에서 값 하나 꺼내기. 예: cls 1:10 stats.packets
cls() { jq -r --arg h "$1" --arg k "$2" \
        '[.[]|select(.handle==$h)]|.[0]|getpath($k|split("."))//empty' <<<"$CLASS"; }
# 들어오는 쪽 표시 규칙에서 값 꺼내기
ped() { jq -r '[.[]|.options.actions[]?|select(.kind=="pedit")]|.[0].keys[0].val//empty' <<<"$1"; }
pip() { jq -r '[.[]|.options.actions[]?|select(.kind=="pedit")]|.[0].control_action.type//empty' <<<"$1"; }
csm() { jq -r '[.[]|.options.actions[]?|select(.kind=="csum")]|length' <<<"$1"; }

echo "1) 길을 OSPF로 배웠는가 (손으로 넣은 static이 아닌가)"
PROTO=$(r1 vtysh -c "show ip route 10.60.3.0/24 json" \
        | jq -r '.["10.60.3.0/24"][]?|select(.selected==true)|.protocol' | head -1)
if [ "$PROTO" = ospf ]; then
  ok "r1이 10.60.3.0/24 로 가는 길을 OSPF로 배움"
else
  bad "r1의 10.60.3.0/24 길이 OSPF가 아님 (${PROTO:-길 없음})" \
      "docker exec -it $P-r1 vtysh -c \"show ip ospf neighbor\" 로 이웃을 확인. static 을 손으로 넣었다면 지울 것"
fi

echo "2) 들어오는 쪽에서 DSCP를 적는 규칙이 걸려 있는가 (분류와 표시)"
V1=$(ped "$ING1"); C1=$(csm "$ING1"); P1=$(pip "$ING1")
V2=$(ped "$ING2"); C2=$(csm "$ING2")
if [ -z "$V1" ]; then
  bad "r1 eth1(h1 쪽)에 표시 규칙이 없음" \
      "docker exec $P-r1 sh /root/mark.sh 로 다시 걸 것"
elif [ "$V1" != b80000 ]; then
  bad "r1 eth1이 EF(0xb8)가 아닌 값($V1)을 적음" \
      "cfg/mark.sh 의 'set 0xb8' 부분을 확인"
elif [ "$P1" != pipe ]; then
  bad "r1 eth1의 pedit 뒤가 pipe 가 아님($P1). 검사값 다시 계산이 안 돌아감" \
      "cfg/mark.sh 처럼 'action pedit ... pipe action csum ip pass' 로 이어 붙일 것"
elif [ "${C1:-0}" = 0 ] || [ "${C2:-0}" = 0 ]; then
  bad "csum(IP 머리 검사값 다시 계산)이 빠짐" \
      "csum 이 없으면 표시한 패킷이 버려짐. cfg/mark.sh 를 다시 돌릴 것"
elif [ "$V2" != 0 ]; then
  bad "r1 eth2(h2 쪽)가 기본값 0이 아닌 값($V2)을 적음" \
      "대량 쪽은 0으로 덮어써야 함. cfg/mark.sh 의 'set 0x00' 부분을 확인"
else
  ok "eth1 -> EF(0xb8), eth2 -> 0 으로 적고 csum 까지 붙음"
fi

echo "3) 좁은 구간 나가는 쪽에 줄이 3개 있는가 (HTB 클래스)"
H10=$(cls 1:10 handle); H20=$(cls 1:20 handle); H30=$(cls 1:30 handle)
if [ -z "$H10" ] || [ -z "$H20" ] || [ -z "$H30" ]; then
  bad "r1 eth3의 줄이 모자람 (있는 줄: ${H10:-없음} ${H20:-없음} ${H30:-없음})" \
      "docker exec $P-r1 sh /root/shape.sh on 으로 줄 3개를 만들 것"
else
  ok "r1 eth3에 중요(1:10), 나머지(1:20), 제어(1:30) 줄이 모두 있음"
fi

echo "4) 줄마다 보장 대역이 맞는가"
R10=$(cls 1:10 rate); R20=$(cls 1:20 rate); R30=$(cls 1:30 rate)
if [ "$R10" != 625000 ] || [ "$R20" != 500000 ] || [ "$R30" != 125000 ]; then
  bad "보장 대역이 다름 (중요 ${R10:-없음} / 나머지 ${R20:-없음} / 제어 ${R30:-없음} 바이트per초)" \
      "중요 5Mbit=625000, 나머지 4Mbit=500000, 제어 1Mbit=125000 이어야 함. cfg/shape.sh 를 확인"
else
  ok "중요 5Mbit, 나머지 4Mbit, 제어 1Mbit 보장이 그대로 들어감"
fi

echo "5) 줄 세우는 기준이 '표시'인가 (주소를 보고 있지 않은가)"
NEF=$(jq -r '[.[]|select(.options.flowid=="1:10")]|length' <<<"$FLT3")
DEF=$(jq -r '[.[]|select(.options.flowid=="1:10" and .options.match.value=="b80000"
             and .options.match.off==0)]|length' <<<"$FLT3")
ADR=$(jq -r '[.[]|select(.options.flowid!=null and ((.options.match.off//0)==12
             or (.options.match.off//0)==16))]|length' <<<"$FLT3")
CS6=$(jq -r '[.[]|select(.options.flowid=="1:30" and .options.match.value=="c00000")]|length' <<<"$FLT3")
if [ "${NEF:-0}" = 0 ]; then
  bad "중요 줄(1:10)로 보내는 규칙이 아예 없음" \
      "docker exec $P-r1 sh /root/shape.sh on 으로 규칙까지 함께 걸 것"
elif [ "${ADR:-0}" != 0 ]; then
  bad "eth3의 규칙이 IP 주소를 보고 줄을 세움 (주소를 보는 규칙 ${ADR}개)" \
      "이 실습은 '경계에서 한 번 표시하고 뒤에서는 표시만 본다'가 목표임. 주소 규칙을 지우고 shape.sh on 으로 다시 걸 것"
elif [ "${DEF:-0}" = 0 ]; then
  bad "중요 줄 규칙이 DSCP EF(0xb8)를 보지 않음" \
      "docker exec $P-r1 tc filter show dev eth3 에서 'match 00b80000/00fc0000' 이 있는지 확인"
elif [ "${CS6:-0}" = 0 ]; then
  bad "제어 줄(1:30) 규칙이 DSCP CS6(0xc0)를 보지 않음" \
      "라우팅 대화(OSPF)가 혼잡에 휘말림. cfg/shape.sh 의 CS6 규칙을 확인"
else
  ok "중요 줄은 EF(0xb8), 제어 줄은 CS6(0xc0) 표시만 보고 세움 (주소를 보는 규칙 0개)"
fi

echo "6) 혼잡을 만들어 잼 (약 10초 걸림)"
B10=$(cls 1:10 stats.packets)
B20=$(cls 1:20 stats.drops)
# 받는 쪽 h3가 보는 표시가 EF인지도 같은 시간에 함께 봄
docker exec "$P-h3" timeout 14 tcpdump -ni eth1 -c 3 -v "icmp and src host 10.60.1.10" \
  > "$T/tos.txt" 2>&1 &
# 중요 흐름을 먼저 띄움. 혼잡이 생긴 뒤에는 iperf3가 연결을 못 맺기 때문임(넷니 실측)
docker exec "$P-h1" iperf3 -c 10.60.3.10 -p 5201 -u -b 5M  -l 1200 -t 8 -J > "$T/ef.json"   2>&1 &
sleep 1
docker exec "$P-h2" iperf3 -c 10.60.3.10 -p 5202 -u -b 20M -l 1200 -t 8 -J > "$T/bulk.json" 2>&1 &
sleep 1
# 대량 쪽은 혼잡해서 ping이 거의 다 버려짐. 그래서 여러 번 보내 하나라도 돌아오게 함
docker exec "$P-h1" ping -c 12 -i 0.5 -W 2 10.60.3.10 > "$T/ping-ef.txt" 2>&1 &
docker exec "$P-h2" ping -c 12 -i 0.5 -W 2 10.60.3.10 > "$T/ping-be.txt" 2>&1 &
wait
CLASS=$(r1 tc -j -s class show dev eth3)
A10=$(cls 1:10 stats.packets)
A20=$(cls 1:20 stats.drops)

# iperf3가 적는 속도는 "보낸 속도"임. 받은 속도 = 보낸 속도 x (1 - 잃은 비율)
RECV=$(jq -r '((.end.sum.bits_per_second//0)/1000000)*((100-(.end.sum.lost_percent//100))/100)
              |.*100|round/100' "$T/ef.json" 2>/dev/null)
LOSS=$(jq -r '(.end.sum.lost_percent//100)|.*100|round/100' "$T/ef.json" 2>/dev/null)
RTE=$(grep -o 'min/avg/max[^ ]* = [^ ]*' "$T/ping-ef.txt" | awk -F'= ' '{print $2}' | cut -d/ -f2)
RTB=$(grep -o 'min/avg/max[^ ]* = [^ ]*' "$T/ping-be.txt" | awk -F'= ' '{print $2}' | cut -d/ -f2)
big() { awk -v a="${1:-0}" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }

# 대량 쪽 ping은 혼잡에 밀려 하나도 안 돌아올 수 있음. 그때는 숫자 대신 그 사실을 적음
if [ -n "$RTB" ]; then RTBD="$RTB ms"; else RTBD="모두 버려져 못 잼"; fi

echo "   (잰 값: 중요 받은 속도 ${RECV:-?} Mbit/s, 잃은 비율 ${LOSS:-?} %," \
     "왕복 시간 중요 ${RTE:-?} ms / 대량 $RTBD)"

echo "7) 중요 트래픽이 중요 줄로 갔는가"
D10=$(( ${A10:-0} - ${B10:-0} ))
DRP=$(cls 1:10 stats.drops)
if [ "$D10" -lt 1000 ]; then
  bad "재는 동안 중요 줄(1:10)로 간 패킷이 ${D10}개뿐임 (1000개 넘게 가야 함)" \
      "2번(표시)과 5번(줄 세우는 기준)부터 고칠 것. 표시가 안 붙으면 중요 트래픽도 나머지 줄로 감"
elif [ "${DRP:-0}" != 0 ]; then
  bad "중요 줄이 ${DRP}개를 버림 (0개여야 함)" \
      "보장 대역(4번)과 보내는 양을 확인. 중요 흐름 5Mbit/s 는 보장 5Mbit/s 안에 들어가야 함"
else
  ok "재는 동안 중요 줄로 ${D10}개가 지나갔고 버린 것은 0개임"
fi

echo "8) 받는 쪽에 EF 표시가 그대로 도착했는가"
if grep -q 'tos 0xb8' "$T/tos.txt"; then
  ok "h3가 받은 중요 패킷의 표시가 EF(tos 0xb8)임"
elif grep -q 'tos 0x' "$T/tos.txt"; then
  bad "h3가 받은 중요 패킷의 표시가 EF가 아님 ($(grep -o 'tos 0x[0-9a-f]*' "$T/tos.txt" | head -1))" \
      "표시 규칙이 지워졌을 수 있음. 2번 항목과 docker exec $P-r1 sh /root/mark.sh 를 확인"
else
  bad "h3가 h1의 패킷을 아예 못 받음" \
      "h1 -> h3 통신부터 확인: docker exec $P-h1 ping -c 3 10.60.3.10"
fi

echo "9) 좁은 구간이 실제로 넘쳤는가 (혼잡이 없으면 아래 검사가 뜻이 없음)"
BLOSS=$(jq -r '(.end.sum.lost_percent//0)|.*100|round/100' "$T/bulk.json" 2>/dev/null)
D20=$(( ${A20:-0} - ${B20:-0} ))
if [ "$D20" -lt 100 ] && ! big "$BLOSS" 20; then
  bad "대량 트래픽이 거의 안 버려짐 (나머지 줄이 버린 것 ${D20}개, 대량 잃은 비율 ${BLOSS:-?} %)" \
      "h2가 20Mbit/s 를 보내는지, 좁은 구간이 10Mbit/s 인지 확인: docker exec $P-r1 tc class show dev eth3"
else
  ok "나머지 줄이 ${D20}개를 버리고 대량 쪽이 ${BLOSS} % 를 잃음. 혼잡이 제대로 생김"
fi

echo "10) 혼잡 속에서도 중요 흐름이 약속한 대역과 짧은 기다림을 받는가"
if [ -z "$RTE" ]; then
  bad "중요 쪽 ping이 하나도 돌아오지 않음 (중요 트래픽도 혼잡에 휩쓸림)" \
      "3번(줄 3개)과 5번(줄 세우는 기준)부터 확인. 표시가 안 붙으면 중요 트래픽도 나머지 줄로 감"
elif ! big "$RECV" 4; then
  bad "중요 흐름이 ${RECV:-?} Mbit/s 밖에 못 받음 (4 Mbit/s 넘게 받아야 함)" \
      "3번(줄 3개)과 4번(보장 대역)부터 확인. 줄이 하나면 대량 트래픽에 밀림"
elif big "$LOSS" 5; then
  bad "중요 흐름이 ${LOSS} % 를 잃음 (5 % 아래여야 함)" \
      "4번 보장 대역이 5Mbit 인지, 중요 줄에 fq_codel 이 걸렸는지 확인"
elif big "$RTE" 10; then
  bad "중요 쪽 왕복 시간이 ${RTE} ms 임 (10 ms 아래여야 함)" \
      "중요 줄 안쪽 큐를 확인: docker exec $P-r1 tc qdisc show dev eth3 에 fq_codel 이 있어야 함"
else
  ok "중요 ${RECV} Mbit/s, 잃은 비율 ${LOSS} %, 기다린 시간 ${RTE} ms (대량 쪽은 $RTBD)"
fi

echo "11) 라우팅 대화(OSPF)가 제어 줄로 따로 빠지는가"
C30=$(cls 1:30 stats.packets)
if [ "${C30:-0}" -lt 1 ]; then
  bad "제어 줄(1:30)로 지나간 패킷이 없음" \
      "CS6 규칙이 걸렸는지 확인(5번). 줄을 방금 새로 깔았다면 10초쯤 뒤 다시 돌려 볼 것"
else
  ok "제어 줄로 OSPF 패킷 ${C30}개가 지나감 (혼잡과 따로 감)"
fi

echo
if [ $fail = 0 ]; then
  echo "결과: 모두 통과"
else
  echo "결과: 실패 항목 있음. 두 번 시도해도 안 되면 ./reset.sh 로 처음 상태로 되돌리세요"
fi
exit $fail
