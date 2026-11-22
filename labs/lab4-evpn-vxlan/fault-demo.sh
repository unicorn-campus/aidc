#!/usr/bin/env bash
# 검사 스크립트가 고장을 잡는지 시험함 (강사 고장 연습용으로도 사용 가능)
# 고장을 하나씩 내고 check.sh 를 돌린 뒤 바로 원상 복구함. 마지막에 모두 통과하는지 확인함
cd "$(dirname "$0")"
P=clab-lab4
cfg() { local n=$1; shift; local a=(); for c in "$@"; do a+=(-c "$c"); done; docker exec "$P-$n" vtysh -c "conf t" "${a[@]}" >/dev/null; }
# leaf의 BGP AS 번호
asn() { [ "$1" = leaf1 ] && echo 65101 || echo 65102; }
evpn_cfg() { local n=$1; shift; cfg "$n" "router bgp $(asn "$n")" "address-family l2vpn evpn" "$@"; }

echo "##### 정상 상태"; ./check.sh; echo

echo "##### 고장1: leaf2가 advertise-all-vni 를 지움 (자기 VNI와 VTEP을 EVPN으로 알리지 않음)"
evpn_cfg leaf2 "no advertise-all-vni"; sleep 6; ./check.sh
evpn_cfg leaf2 "advertise-all-vni"; sleep 8; echo

echo "##### 고장2: leaf1이 EVPN 이웃 활성화를 지움 (neighbor fabric activate 없음)"
evpn_cfg leaf1 "no neighbor fabric activate"; sleep 6; ./check.sh
evpn_cfg leaf1 "neighbor fabric activate"
# 다시 켠 뒤에는 EVPN 이웃을 한 번 다시 맺게 해야 경로를 주고받음(실측으로 확인한 FRR 동작)
docker exec $P-leaf1 vtysh -c "clear bgp l2vpn evpn *" >/dev/null; sleep 12; echo

echo "##### 고장3: leaf2가 자기 루프백(VTEP 주소)을 BGP로 알리지 않음"
cfg leaf2 "router bgp 65102" "address-family ipv4 unicast" "no network 10.0.0.12/32"; sleep 8; ./check.sh
cfg leaf2 "router bgp 65102" "address-family ipv4 unicast" "network 10.0.0.12/32"; sleep 10; echo

echo "##### 고장4(편법): EVPN을 끄고 fdb에 상대 VTEP을 손으로 넣어 통신만 살림"
# 통신은 되지만 EVPN으로 배운 것이 아니므로 2, 3, 4번 항목이 잡아야 함
evpn_cfg leaf1 "no advertise-all-vni"; evpn_cfg leaf2 "no advertise-all-vni"; sleep 5
docker exec $P-leaf1 bridge fdb append 00:00:00:00:00:00 dev vxlan100 dst 10.0.0.12
docker exec $P-leaf2 bridge fdb append 00:00:00:00:00:00 dev vxlan100 dst 10.0.0.11
sleep 2; ./check.sh
docker exec $P-leaf1 bridge fdb del 00:00:00:00:00:00 dev vxlan100 dst 10.0.0.12
docker exec $P-leaf2 bridge fdb del 00:00:00:00:00:00 dev vxlan100 dst 10.0.0.11
evpn_cfg leaf1 "advertise-all-vni"; evpn_cfg leaf2 "advertise-all-vni"; sleep 10; echo

echo "##### 복구 확인"; ./check.sh
