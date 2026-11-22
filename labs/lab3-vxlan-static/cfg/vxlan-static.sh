#!/bin/sh
# lab3: leaf에서 VxLAN 터널을 손으로 만듦
# 사용: sh vxlan-static.sh <내 VTEP 주소> <상대 VTEP 주소>
#   예) leaf1: sh vxlan-static.sh 10.0.0.11 10.0.0.12
set -e
LOCAL=$1    # 내 루프백 주소. 터널 바깥 IP 머리의 출발지가 됨
REMOTE=$2   # 상대 leaf 루프백 주소. 손으로 적는 부분
VNI=100     # 두 leaf가 같은 번호를 써야 같은 망으로 묶임

# 1) 브리지(스위치 역할) br100을 만듦
ip link add br100 type bridge
ip link set br100 up

# 2) VxLAN 인터페이스 vxlan100: VNI 100, 표준 UDP 포트 4789, 출발지는 내 루프백
ip link add vxlan100 type vxlan id $VNI dstport 4789 local $LOCAL
ip link set vxlan100 master br100
ip link set vxlan100 up

# 3) 서버 쪽 포트 eth3도 같은 브리지에 꽂음(IP 없음, 2계층 포트)
ip link set eth3 mtu 1500
ip link set eth3 master br100
ip link set eth3 up

# 4) 모르는 목적지(브로드캐스트 포함)는 상대 VTEP으로 보내라고 손으로 적음
#    00:00:00:00:00:00 은 "기본 행선지"라는 뜻. 상대 leaf가 늘면 줄도 늘려야 함
bridge fdb append 00:00:00:00:00:00 dev vxlan100 dst $REMOTE

echo "vxlan100 준비 완료: local=$LOCAL remote=$REMOTE vni=$VNI"
