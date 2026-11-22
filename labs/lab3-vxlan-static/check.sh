#!/usr/bin/env bash
# lab3 검사: "통신이 되는가"뿐 아니라 "손으로 만든 VxLAN 터널이 의도대로 만들어졌는가"를 확인함
# 사용: ./check.sh
P=clab-lab3
fail=0

ok()   { echo "  [통과] $1"; }
bad()  { echo "  [실패] $1"; echo "         힌트: $2"; fail=1; }
vty()  { docker exec "$P-$1" vtysh -c "$2" 2>/dev/null; }

# leaf별 정보: 이름 내VTEP 상대VTEP
LEAVES="leaf1:10.0.0.11:10.0.0.12 leaf2:10.0.0.12:10.0.0.11"

echo "1) leaf마다 spine 2대와 BGP 이웃이 맺어졌는가 (언더레이)"
for e in $LEAVES; do leaf=${e%%:*}
  n=$(vty "$leaf" "show bgp summary json" | jq '[.ipv4Unicast.peers[]? | select(.state=="Established")] | length')
  if [ "$n" = "2" ]; then ok "$leaf: 이웃 2개 정상"
  else bad "$leaf: 정상 이웃 ${n:-0}개 (2개여야 함)" "docker exec -it $P-$leaf vtysh 로 들어가 show bgp summary 를 확인"; fi
done

echo "2) 상대 VTEP 주소(루프백)를 BGP로 배웠고, 두 spine을 모두 쓰는가"
for e in $LEAVES; do IFS=: read leaf me peer <<<"$e"
  r=$(vty "$leaf" "show ip route $peer/32 json" | jq -c --arg p "$peer/32" '.[$p][]? | select(.selected==true) | {protocol, n: ([.nexthops[] | select(.active==true)] | length)}')
  proto=$(echo "$r" | jq -r '.protocol // empty'); n=$(echo "$r" | jq -r '.n // 0')
  if [ -z "$proto" ]; then bad "$leaf: 상대 VTEP $peer 로 가는 길이 없음" "상대 leaf의 network 문장과 BGP 이웃 상태를 확인"
  elif [ "$proto" != "bgp" ]; then bad "$leaf: $peer 경로가 BGP가 아니라 $proto 경로임" "언더레이는 BGP로 배워야 함. 손으로 넣은 경로를 지우세요"
  elif [ "$n" != "2" ]; then bad "$leaf: $peer 경로가 ${n}개 길로만 감 (2개여야 함)" "spine 쪽 선 하나 또는 BGP 이웃 하나가 끊겼는지 확인"
  else ok "$leaf: $peer 를 BGP로 배웠고 길 2개 사용"; fi
done

echo "3) vxlan100이 VNI 100, 내 루프백, UDP 4789로 만들어졌는가"
for e in $LEAVES; do IFS=: read leaf me peer <<<"$e"
  v=$(docker exec "$P-$leaf" ip -j -d link show vxlan100 2>/dev/null | jq -c '.[0].linkinfo.info_data // empty')
  id=$(echo "$v" | jq -r '.id // empty'); lo=$(echo "$v" | jq -r '.local // empty'); pt=$(echo "$v" | jq -r '.port // empty')
  if [ -z "$v" ]; then bad "$leaf: vxlan100 인터페이스가 없음" "ip link add vxlan100 type vxlan id 100 dstport 4789 local $me 로 만들고 br100에 꽂기"
  elif [ "$id" != "100" ]; then bad "$leaf: VNI가 $id (100이어야 함)" "두 leaf의 VNI가 같아야 같은 망으로 묶임"
  elif [ "$lo" != "$me" ]; then bad "$leaf: local 주소가 $lo (내 루프백 $me 여야 함)" "터널 바깥 머리의 출발지가 틀림. vxlan100을 지우고 local $me 로 다시 만들 것"
  elif [ "$pt" != "4789" ]; then bad "$leaf: 포트가 $pt (4789여야 함)" "dstport 4789 로 다시 만들 것"
  else ok "$leaf: vxlan100 = VNI 100, local $me, 포트 4789"; fi
done

echo "4) 상대 VTEP을 fdb에 손으로 적었고, EVPN은 쓰지 않는가"
for e in $LEAVES; do IFS=: read leaf me peer <<<"$e"
  dsts=$(docker exec "$P-$leaf" bridge -j fdb show dev vxlan100 2>/dev/null | jq -r '.[] | select(.mac=="00:00:00:00:00:00" and .state=="permanent") | .dst' | sort -u | tr '\n' ' ')
  evpn=$(vty "$leaf" "show evpn vni json" | jq -r 'if type=="object" then length else 0 end')
  if [ -z "$dsts" ]; then bad "$leaf: fdb에 손으로 적은 상대 VTEP 줄이 없음" "bridge fdb append 00:00:00:00:00:00 dev vxlan100 dst $peer 를 입력"
  elif [ "$dsts" != "$peer " ]; then bad "$leaf: fdb의 상대 VTEP이 '${dsts% }' (상대는 $peer)" "주소를 틀리게 적음. bridge fdb del 로 지우고 $peer 로 다시 적을 것"
  elif [ "${evpn:-0}" != "0" ]; then bad "$leaf: EVPN이 켜져 있음" "이 실습은 EVPN 없이 손으로 하는 것이 목표임. BGP의 l2vpn evpn 설정을 지울 것"
  else ok "$leaf: fdb에 상대 VTEP $peer 를 손으로 적었고 EVPN은 꺼져 있음"; fi
done

echo "5) 서버 h1에서 h2로 통신되는가"
if docker exec $P-h1 ping -c 2 -W 1 10.10.10.12 >/dev/null 2>&1; then ok "h1 -> h2 통신 정상"
else bad "h1 -> h2 통신 안 됨" "위 1 ~ 4번에서 실패한 항목부터 고치고, h1, h2의 IP(10.10.10.11, .12)와 br100 연결을 확인"; fi

echo
if [ $fail = 0 ]; then echo "결과: 모두 통과"; else echo "결과: 실패 항목 있음. 두 번 시도해도 안 되면 ./reset.sh 로 처음 상태로 되돌리세요"; fi
exit $fail
