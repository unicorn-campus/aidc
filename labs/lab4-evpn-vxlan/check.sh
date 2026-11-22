#!/usr/bin/env bash
# lab4 검사: "통신이 되는가"뿐 아니라 "EVPN이 VTEP과 MAC을 자동으로 배웠는가"를 확인함
# 사용: ./check.sh
P=clab-lab4
fail=0

ok()   { echo "  [통과] $1"; }
bad()  { echo "  [실패] $1"; echo "         힌트: $2"; fail=1; }
vty()  { docker exec "$P-$1" vtysh -c "$2" 2>/dev/null; }
fdb()  { docker exec "$P-$1" bridge -j fdb show dev vxlan100 2>/dev/null; }

# leaf별 정보: 이름 내VTEP 상대VTEP
LEAVES="leaf1:10.0.0.11:10.0.0.12 leaf2:10.0.0.12:10.0.0.11"

# 먼저 서버끼리 ping을 함. 서버 MAC은 서버가 패킷을 보내야 leaf가 배우고 EVPN으로 알리기 때문임
# (조용한 MAC은 시간이 지나면 빠질 수 있으므로 매번 검사 전에 함)
docker exec $P-h2 ping -c 2 -W 1 10.10.10.11 >/dev/null 2>&1
if docker exec $P-h1 ping -c 2 -W 1 10.10.10.12 >/dev/null 2>&1; then PING=1; else PING=0; fi
sleep 2   # 배운 MAC이 EVPN 경로로 퍼질 시간

echo "1) leaf마다 spine 2대와 BGP 이웃(ipv4, l2vpn evpn)이 맺어졌고 상대 VTEP 주소로 가는 길이 있는가"
for e in $LEAVES; do IFS=: read leaf me peer <<<"$e"
  n4=$(vty "$leaf" "show bgp summary json" | jq '[.ipv4Unicast.peers[]? | select(.state=="Established")] | length')
  ne=$(vty "$leaf" "show bgp l2vpn evpn summary json" | jq '[(.peers // .l2VpnEvpn.peers // {})[] | select(.state=="Established")] | length')
  nz=$(vty "$leaf" "show bgp l2vpn evpn summary json" | jq '[(.peers // .l2VpnEvpn.peers // {})[] | select(.state=="Established" and .tableVersion>0)] | length')
  rp=$(vty "$leaf" "show ip route $peer/32 json" | jq -r --arg p "$peer/32" '[.[$p][]? | select(.selected==true)] | .[0].protocol // empty')
  if [ "$n4" != "2" ]; then bad "$leaf: ipv4 이웃 ${n4:-0}개 (2개여야 함)" "docker exec -it $P-$leaf vtysh 로 들어가 show bgp summary 를 확인"
  elif [ "$ne" != "2" ]; then bad "$leaf: EVPN 이웃 ${ne:-0}개 (2개여야 함)" "address-family l2vpn evpn 안에 neighbor fabric activate 가 있는지 확인 (spine도 같음)"
  elif [ "$nz" != "2" ]; then bad "$leaf: EVPN 이웃은 붙었지만 경로를 주고받지 못함 (경로 교환 ${nz:-0}개)" "vtysh -c \"clear bgp l2vpn evpn *\" 로 EVPN 이웃을 다시 맺게 하고 show bgp l2vpn evpn summary 를 확인"
  elif [ "$rp" != "bgp" ]; then bad "$leaf: 상대 VTEP $peer 로 가는 길이 BGP에 없음 (${rp:-경로 없음})" "상대 leaf의 network $peer/32 문장과 BGP 이웃 상태를 확인. EVPN 경로도 이 길이 있어야 쓸 수 있음"
  else ok "$leaf: ipv4와 EVPN 이웃 2개씩 정상, 상대 VTEP $peer 를 BGP로 배움"; fi
done

echo "2) 상대 VTEP을 손으로 적지 않고 EVPN으로 배웠는가"
for e in $LEAVES; do IFS=: read leaf me peer <<<"$e"
  vni=$(vty "$leaf" "show evpn vni 100 json")
  vtep=$(echo "$vni" | jq -r '.vtepIp // empty')
  has=$(echo "$vni" | jq -r --arg p "$peer" '[.remoteVteps[]? | select(.ip==$p)] | length')
  t3=$(vty "$leaf" "show bgp l2vpn evpn route type multicast json" | jq -r --arg k "[3]:[0]:[32]:[$peer]" 'any(.[]? | objects; has($k))')
  if [ -z "$vtep" ]; then bad "$leaf: EVPN이 VNI 100을 모름 (내 VTEP 정보가 없음)" "BGP address-family l2vpn evpn 안에 advertise-all-vni 가 있는지 확인"
  elif [ "$t3" != "true" ]; then bad "$leaf: 상대 VTEP $peer 의 EVPN 경로(타입 3)가 없음" "상대 leaf에서 advertise-all-vni 와 EVPN 이웃(neighbor fabric activate)을 확인"
  elif [ "$has" != "1" ]; then bad "$leaf: EVPN 경로는 왔지만 원격 VTEP 목록에 $peer 가 없음" "vtysh -c \"show evpn vni 100\" 로 Remote VTEPs 를 확인"
  else ok "$leaf: 원격 VTEP $peer 를 EVPN으로 배움 (타입 3 경로 있음)"; fi
done

echo "3) 상대 서버 MAC을 EVPN으로 배웠는가"
for e in $LEAVES; do IFS=: read leaf me peer <<<"$e"
  nm=$(vty "$leaf" "show evpn mac vni 100 json" | jq -r --arg p "$peer" '[.macs[]? | select(.type=="remote" and .remoteVtep==$p)] | length')
  ne=$(fdb "$leaf" | jq -r --arg p "$peer" '[.[] | select(.dst==$p and .mac!="00:00:00:00:00:00" and (.flags | index("extern_learn")))] | length')
  lr=$(docker exec "$P-$leaf" ip -j -d link show vxlan100 2>/dev/null | jq -r '.[0].linkinfo.info_data.learning')
  if [ "${nm:-0}" = "0" ]; then bad "$leaf: $peer 뒤의 원격 MAC(remote)이 EVPN 표에 없음" "show evpn mac vni 100 확인. 상대 leaf의 advertise-all-vni 와 서버 ping 여부를 확인"
  elif [ "${ne:-0}" = "0" ]; then bad "$leaf: 원격 MAC이 커널 fdb에 extern_learn 표시로 들어오지 않음" "bridge fdb show dev vxlan100 으로 확인. FRR(zebra) 상태를 점검"
  elif [ "$lr" != "false" ]; then bad "$leaf: vxlan100의 learning 이 켜져 있음 (nolearning 이어야 함)" "EVPN이 알려 준 MAC만 쓰게 vxlan100을 nolearning 으로 만들 것"
  else ok "$leaf: 원격 MAC ${nm}개를 EVPN으로 배움 (타입 2, fdb extern_learn)"; fi
done

echo "4) fdb에 손으로 적은 줄이 없는가"
for e in $LEAVES; do IFS=: read leaf me peer <<<"$e"
  known=$(vty "$leaf" "show evpn vni 100 json" | jq -r '[.remoteVteps[]?.ip] | sort | join(" ")')
  defs=$(fdb "$leaf" | jq -r '[.[] | select(.mac=="00:00:00:00:00:00" and .dst) | .dst] | unique | join(" ")')
  hand=$(fdb "$leaf" | jq -r '[.[] | select(.dst and .mac!="00:00:00:00:00:00" and ((.flags | index("extern_learn")) | not))] | length')
  if [ "$defs" != "$known" ]; then bad "$leaf: fdb의 VTEP 줄 '${defs:-없음}' 이 EVPN이 배운 VTEP '${known:-없음}' 과 다름 (손으로 넣은 줄이 있음)" "이 실습은 EVPN이 VTEP을 배우게 하는 것이 목표임. bridge fdb del 로 지우고 BGP l2vpn evpn 설정을 확인"
  elif [ "$hand" != "0" ]; then bad "$leaf: fdb에 손으로 넣은 MAC 줄이 ${hand}개 있음" "bridge fdb show dev vxlan100 에서 extern_learn 이 없는 줄을 bridge fdb del 로 지울 것"
  else ok "$leaf: fdb에 손으로 넣은 줄이 없음 (VTEP은 EVPN이 넣은 것뿐)"; fi
done

echo "5) 서버 h1에서 h2로 통신되는가"
if [ "$PING" = 1 ]; then ok "h1 -> h2 통신 정상"
else bad "h1 -> h2 통신 안 됨" "위 1 ~ 4번에서 실패한 항목부터 고치고, h1, h2의 IP(10.10.10.11, .12)와 br100 연결을 확인"; fi

echo
if [ $fail = 0 ]; then echo "결과: 모두 통과"; else echo "결과: 실패 항목 있음. 두 번 시도해도 안 되면 ./reset.sh 로 처음 상태로 되돌리세요"; fi
exit $fail
