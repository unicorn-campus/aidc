#!/usr/bin/env bash
# 검사 스크립트가 고장을 잡는지 시험함 (강사 고장 연습용으로도 사용 가능)
cd "$(dirname "$0")"
P=clab-lab1
cfg() { local n=$1; shift; local a=(); for c in "$@"; do a+=(-c "$c"); done; docker exec "$P-$n" vtysh -c "conf t" "${a[@]}" >/dev/null; }
# 검사 결과가 바뀔 때까지 기다림(최대 60초). $1=fail 이면 실패가 될 때까지, pass 이면 통과가 될 때까지
settle() {
  local want=$1 i
  for i in $(seq 1 60); do
    if ./check.sh >/dev/null 2>&1; then [ "$want" = pass ] && return; else [ "$want" = fail ] && return; fi
    sleep 1
  done
}

echo "##### 정상 상태"; ./check.sh; echo

echo "##### 고장1: sw1과 sw2 사이 선 끊기"
docker exec $P-sw1 ip link set eth1 down; settle fail; ./check.sh
docker exec $P-sw1 ip link set eth1 up; settle pass; echo

echo "##### 고장2: sw2가 선(192.168.12.0/30)을 OSPF에 넣지 않음"
cfg sw2 "router ospf" "no network 192.168.12.0/30 area 0"; settle fail; ./check.sh
cfg sw2 "router ospf" "network 192.168.12.0/30 area 0"; settle pass; echo

echo "##### 고장3: sw2의 hello 간격만 다르게 바꿈(5초). 이웃이 끊어질 때까지 기다림"
cfg sw2 "interface eth1" "ip ospf hello-interval 5"; settle fail; ./check.sh
cfg sw2 "interface eth1" "no ip ospf hello-interval"; settle pass; echo

echo "##### 고장4: sw2 선 주소를 오타 냄(192.168.12.2 -> 192.168.13.2)"
cfg sw2 "interface eth1" "no ip address 192.168.12.2/30" "ip address 192.168.13.2/30"; settle fail; ./check.sh
cfg sw2 "interface eth1" "no ip address 192.168.13.2/30" "ip address 192.168.12.2/30"; settle pass; echo

echo "##### 고장5(편법): 루프백을 OSPF에서 빼고, 손으로 넣은 경로(static)로 통신만 되게 함"
cfg sw1 "router ospf" "no network 10.0.0.1/32 area 0" "ip route 10.0.0.2/32 192.168.12.2"
cfg sw2 "router ospf" "no network 10.0.0.2/32 area 0" "ip route 10.0.0.1/32 192.168.12.1"
settle fail; ./check.sh
cfg sw1 "no ip route 10.0.0.2/32 192.168.12.2" "router ospf" "network 10.0.0.1/32 area 0"
cfg sw2 "no ip route 10.0.0.1/32 192.168.12.1" "router ospf" "network 10.0.0.2/32 area 0"
settle pass; echo

echo "##### 복구 확인"; ./check.sh
