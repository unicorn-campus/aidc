#!/usr/bin/env bash
# 검사 스크립트가 고장을 잡는지 시험함 (강사 고장 연습용으로도 사용 가능)
# 고장을 하나씩 내고 check.sh 를 돌린 뒤 바로 원상 복구함. 마지막에 모두 통과하는지 확인함
cd "$(dirname "$0")"
P=clab-lab3
cfg() { local n=$1; shift; local a=(); for c in "$@"; do a+=(-c "$c"); done; docker exec "$P-$n" vtysh -c "conf t" "${a[@]}" >/dev/null; }
sh_() { local n=$1; shift; docker exec "$P-$n" sh -c "$*"; }
# vxlan100을 지우고 다시 만듦: $1=leaf $2=local 주소 $3=fdb에 적을 상대 주소(없으면 적지 않음)
remake() {
  sh_ "$1" "ip link del vxlan100 2>/dev/null; ip link add vxlan100 type vxlan id 100 dstport 4789 local $2 && ip link set vxlan100 master br100 && ip link set vxlan100 up"
  [ -n "$3" ] && sh_ "$1" "bridge fdb append 00:00:00:00:00:00 dev vxlan100 dst $3"
}

echo "##### 정상 상태"; ./check.sh; echo

echo "##### 고장1: leaf1이 fdb에 상대 VTEP 주소를 틀리게 적음 (10.0.0.12 대신 10.0.0.21)"
sh_ leaf1 "bridge fdb del 00:00:00:00:00:00 dev vxlan100 dst 10.0.0.12; bridge fdb append 00:00:00:00:00:00 dev vxlan100 dst 10.0.0.21"
sleep 2; ./check.sh
remake leaf1 10.0.0.11 10.0.0.12; echo

echo "##### 고장2: leaf1이 fdb에 상대 VTEP 줄을 빼먹음"
sh_ leaf1 "bridge fdb del 00:00:00:00:00:00 dev vxlan100 dst 10.0.0.12"
sleep 2; ./check.sh
remake leaf1 10.0.0.11 10.0.0.12; echo

echo "##### 고장3: leaf2의 vxlan100 local 주소가 틀림 (10.0.0.12 대신 10.0.0.22)"
remake leaf2 10.0.0.22 10.0.0.11
sleep 2; ./check.sh
remake leaf2 10.0.0.12 10.0.0.11; echo

echo "##### 고장4: leaf2가 자기 루프백(VTEP 주소)을 BGP로 알리지 않음"
cfg leaf2 "router bgp 65102" "address-family ipv4 unicast" "no network 10.0.0.12/32"; sleep 6; ./check.sh
cfg leaf2 "router bgp 65102" "address-family ipv4 unicast" "network 10.0.0.12/32"; sleep 8; echo

echo "##### 고장5(편법): leaf1이 BGP 대신 손으로 넣은 경로(static)로 상대 VTEP에 닿게 함"
# 통신은 되지만 언더레이를 BGP로 배운 것이 아니므로 2번 항목이 잡아야 함
cfg leaf1 "ip route 10.0.0.12/32 10.0.0.1" "ip route 10.0.0.12/32 10.0.0.2"; sleep 3; ./check.sh
cfg leaf1 "no ip route 10.0.0.12/32 10.0.0.1" "no ip route 10.0.0.12/32 10.0.0.2"; echo

echo "##### 복구 확인"; sleep 5; ./check.sh
