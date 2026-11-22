#!/usr/bin/env bash
# 검사 스크립트가 고장을 잡는지 시험함 (강사 고장 연습용으로도 사용 가능)
cd "$(dirname "$0")"
P=clab-lab2
cfg() { local n=$1; shift; local a=(); for c in "$@"; do a+=(-c "$c"); done; docker exec "$P-$n" vtysh -c "conf t" "${a[@]}" >/dev/null; }

echo "##### 정상 상태"; ./check.sh; echo

echo "##### 고장1: leaf1과 spine1 사이 선 끊기"
docker exec $P-leaf1 ip link set eth1 down; sleep 5; ./check.sh
docker exec $P-leaf1 ip link set eth1 up; echo

echo "##### 고장2: leaf2가 서버 대역(192.168.2.0/24)을 광고하지 않음"
cfg leaf2 "router bgp 65102" "address-family ipv4 unicast" "no network 192.168.2.0/24"; sleep 5; ./check.sh
cfg leaf2 "router bgp 65102" "address-family ipv4 unicast" "network 192.168.2.0/24"; echo

echo "##### 고장3(편법): BGP 대신 손으로 넣은 경로(static)로 통신만 되게 함"
sleep 10
# spine 1대로만 넣으면 통신이 끊김(원인 미확인). 2대 모두로 넣으면 통신은 됨
cfg leaf1 "ip route 192.168.2.0/24 10.0.0.1" "ip route 192.168.2.0/24 10.0.0.2"; sleep 3; ./check.sh
cfg leaf1 "no ip route 192.168.2.0/24 10.0.0.1" "no ip route 192.168.2.0/24 10.0.0.2"; echo

echo "##### 복구 확인"; sleep 5; ./check.sh
