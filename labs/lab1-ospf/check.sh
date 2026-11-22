#!/usr/bin/env bash
# lab1 검사: "통신이 되는가"뿐 아니라 "OSPF로 배웠는가"를 확인함
# 사용: ./check.sh
P=clab-lab1
fail=0

ok()   { echo "  [통과] $1"; }
bad()  { echo "  [실패] $1"; echo "         힌트: $2"; fail=1; }
vty()  { docker exec "$P-$1" vtysh -c "$2" 2>/dev/null; }

echo "1) 두 스위치가 OSPF 이웃(Full)이 되었는가"
for sw in sw1 sw2; do
  # Full 상태인 이웃의 수를 셈
  n=$(vty "$sw" "show ip ospf neighbor json" | jq '[.neighbors[]?[]? | select(.nbrState | startswith("Full"))] | length' 2>/dev/null)
  if [ "$n" = "1" ]; then ok "$sw: 이웃 1개가 Full 상태"
  else bad "$sw: Full 상태인 이웃이 ${n:-0}개 (1개여야 함)" "docker exec -it $P-$sw vtysh 로 들어가 show ip ospf neighbor 와 show ip ospf interface eth1 을 확인(선, 링크 주소, hello 간격, network 문장)"; fi
done

echo "2) 상대 루프백을 OSPF로 배웠는가"
check_route() { # $1=스위치 $2=상대 루프백
  proto=$(vty "$1" "show ip route $2 json" | jq -r --arg p "$2" '.[$p][]? | select(.selected==true) | .protocol' 2>/dev/null | head -1)
  if [ -z "$proto" ]; then bad "$1: $2 경로가 없음" "상대 스위치 router ospf 의 network 문장과 OSPF 이웃 상태를 확인"
  elif [ "$proto" != "ospf" ]; then bad "$1: $2 경로가 OSPF가 아니라 '$proto'로 들어옴" "손으로 넣은 경로는 이 실습의 답이 아님. 지우고 router ospf 의 network 문장을 확인"
  else ok "$1: $2 를 OSPF로 배움"; fi
}
check_route sw1 10.0.0.2/32
check_route sw2 10.0.0.1/32

echo "3) 루프백끼리 통신되는가"
if docker exec $P-sw1 ping -c 2 -W 1 -I 10.0.0.1 10.0.0.2 >/dev/null 2>&1; then ok "sw1(10.0.0.1) -> sw2(10.0.0.2) 통신 정상"
else bad "sw1(10.0.0.1) -> sw2(10.0.0.2) 통신 안 됨" "선(eth1)과 링크 주소(192.168.12.0/30)를 확인"; fi
if docker exec $P-sw2 ping -c 2 -W 1 -I 10.0.0.2 10.0.0.1 >/dev/null 2>&1; then ok "sw2(10.0.0.2) -> sw1(10.0.0.1) 통신 정상"
else bad "sw2(10.0.0.2) -> sw1(10.0.0.1) 통신 안 됨" "선(eth1)과 링크 주소(192.168.12.0/30)를 확인"; fi

echo
if [ $fail = 0 ]; then echo "결과: 모두 통과"; else echo "결과: 실패 항목 있음. 두 번 시도해도 안 되면 ./reset.sh 로 처음 상태로 되돌리세요"; fi
exit $fail
