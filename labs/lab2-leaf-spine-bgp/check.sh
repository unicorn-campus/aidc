#!/usr/bin/env bash
# lab2 검사: "통신이 되는가"뿐 아니라 "BGP로 제대로 되는가"를 확인함
# 사용: ./check.sh
P=clab-lab2
fail=0

ok()   { echo "  [통과] $1"; }
bad()  { echo "  [실패] $1"; echo "         힌트: $2"; fail=1; }
vty()  { docker exec "$P-$1" vtysh -c "$2" 2>/dev/null; }

echo "1) leaf마다 spine 2대와 BGP 이웃이 맺어졌는가"
for leaf in leaf1 leaf2; do
  n=$(vty "$leaf" "show bgp summary json" | jq '[.ipv4Unicast.peers[] | select(.state=="Established")] | length')
  if [ "$n" = "2" ]; then ok "$leaf: 이웃 2개 정상"
  else bad "$leaf: 정상 이웃 ${n:-0}개 (2개여야 함)" "docker exec -it $P-$leaf vtysh 로 들어가 show bgp summary 를 확인"; fi
done

echo "2) 상대편 서버 대역을 BGP로 배웠고, 두 spine을 모두 쓰는가(ECMP)"
check_route() { # $1=leaf $2=대역
  r=$(vty "$1" "show ip route $2 json" | jq -c --arg p "$2" '.[$p][]? | select(.selected==true) | {protocol, n: ([.nexthops[] | select(.active==true)] | length)}')
  proto=$(echo "$r" | jq -r '.protocol // empty'); n=$(echo "$r" | jq -r '.n // 0')
  if [ -z "$proto" ]; then bad "$1: $2 경로가 없음" "상대 leaf 설정의 network 문장과 BGP 이웃 상태를 확인"
  elif [ "$proto" != "bgp" ]; then bad "$1: $2 경로가 BGP가 아니라 '$proto'로 들어옴" "손으로 넣은 경로(static)는 이 실습의 답이 아님. 지우고 BGP로 배우게 할 것"
  elif [ "$n" != "2" ]; then bad "$1: $2 경로가 ${n}개 길로만 감 (2개여야 함)" "spine 쪽 선 하나 또는 BGP 이웃 하나가 끊겼는지 확인"
  else ok "$1: $2 를 BGP로 배웠고 길 2개 사용"; fi
}
check_route leaf1 192.168.2.0/24
check_route leaf2 192.168.1.0/24

echo "3) 서버 h1에서 h2로 통신되는가"
if docker exec $P-h1 ping -c 2 -W 1 192.168.2.10 >/dev/null 2>&1; then ok "h1 -> h2 통신 정상"
else bad "h1 -> h2 통신 안 됨" "h1, h2의 IP와 기본 경로, leaf의 eth3 주소를 확인"; fi

echo
if [ $fail = 0 ]; then echo "결과: 모두 통과"; else echo "결과: 실패 항목 있음. 두 번 시도해도 안 되면 ./reset.sh 로 처음 상태로 되돌리세요"; fi
exit $fail
