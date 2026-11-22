#!/bin/sh
# lab4: leaf에 VxLAN 터널 "틀"만 만듦. 상대 VTEP은 적지 않음
# 상대 VTEP과 상대 서버 MAC은 BGP EVPN이 알려 주고, FRR(zebra)이 fdb에 넣어 줌
# 사용: sh vxlan-evpn.sh <내 VTEP 주소>
#   예) leaf1: sh vxlan-evpn.sh 10.0.0.11
set -e
LOCAL=$1    # 내 루프백 주소. 터널 바깥 IP 머리의 출발지가 됨
VNI=100     # 두 leaf가 같은 번호를 써야 같은 망으로 묶임

# 1) 브리지(스위치 역할) br100을 만듦
ip link add br100 type bridge
ip link set br100 up

# 2) VxLAN 인터페이스 vxlan100
#    nolearning: 터널로 들어온 패킷을 보고 MAC을 배우지 않음(EVPN이 알려 준 것만 씀)
ip link add vxlan100 type vxlan id $VNI dstport 4789 local $LOCAL nolearning
ip link set vxlan100 master br100
bridge link set dev vxlan100 learning off
ip link set vxlan100 up

# 3) 서버 쪽 포트 eth3도 같은 브리지에 꽂음(IP 없음, 2계층 포트)
ip link set eth3 mtu 1500
ip link set eth3 master br100
ip link set eth3 up

# lab3과 달리 "bridge fdb append 00:00:00:00:00:00 ... dst <상대>" 줄이 없음
echo "vxlan100 준비 완료(EVPN 방식): local=$LOCAL vni=$VNI"
