#!/usr/bin/env bash
# lab5 검사: "통신이 되는가"가 아니라 "RDMA 가 RoCEv2(UDP 4791)로 상대 VM 과 오가는가"를 봄
#
#   ./check.sh          # 다섯 항목을 차례로 봄. 하나라도 실패하면 끝코드가 0 이 아님
#
# 검사하는 것
#   1) 두 VM 이 켜져 있고 내부망으로 서로 보이는가
#   2) RDMA 장치 rxe0 이 켜져 있고 내부망 랜카드에 붙었는가
#   3) rxe0 의 GID 표에 내부망 IP 를 담은 RoCEv2 자리가 있는가
#   4) RDMA 프로그램이 상대 VM 과 통신하는가
#   5) 그 통신이 RoCEv2(UDP 4791)로 내부망을 오가는가

cd "$(dirname "$0")" || exit 1
. ./_common.sh
# _common.sh 의 set -euo pipefail 을 끔. 검사는 실패해도 끝까지 가야 하기 때문임
set +e +u +o pipefail

fail=0
ok()  { echo "  [통과] $1"; }
bad() { echo "  [실패] $1"; echo "         힌트: $2"; fail=1; }

[ -x "$VBM" ] || { echo "VBoxManage 를 찾지 못함: $VBM"; exit 1; }
[ -f "$KEY_RUN" ] || prepare_key

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# VM 에 ssh 를 새로 붙을 때마다 이 PC 에서는 2초 안팎이 걸림.
# 한 번 붙은 길을 2분 동안 다시 쓰도록 ssh 를 감싸 둠
ssh() {
  command ssh -o ControlMaster=auto -o ControlPath="$TMP/cm-%r@%h:%p" -o ControlPersist=120 "$@"
}

# VM 이름마다 내부망 주소를 미리 풀어 둠
declare -A IP NETDEV GIDIDX DATA RUNNING
for n in $VM_NAMES; do
  load_spec "$n"
  IP[$n]="$VM_IP"
done
# 첫 번째 VM 을 rping 서버, 두 번째 VM 을 손님으로 씀
SRV="$(echo $VM_NAMES | awk '{print $1}')"
CLI="$(echo $VM_NAMES | awk '{print $2}')"
SRV_IP="${IP[$SRV]}"
CLI_IP="${IP[$CLI]}"

# 상대 VM 이름을 돌려줌
peer_of() { [ "$1" = "$SRV" ] && echo "$CLI" || echo "$SRV"; }

# 10.50.0.11 -> 0000:0000:0000:0000:0000:ffff:0a32:000b (GID 표에 적히는 모양)
ip_to_gid() {
  local o
  o=(${1//./ })
  printf '0000:0000:0000:0000:0000:ffff:%02x%02x:%02x%02x\n' "${o[0]}" "${o[1]}" "${o[2]}" "${o[3]}"
}

# VM 안에서 봐야 할 것을 한 번에 모아 옴. 뒤에서 ###이름 구간별로 꺼내 씀
collect() {
  vm_ssh "$1" "
echo '###IP'
ip -o -4 addr show
echo '###RDMA'
rdma link show 2>/dev/null
echo '###GID'
D=/sys/class/infiniband/rxe0/ports/1
# GID 자리는 수천 개이고 거의 다 0 임. 0 이 아닌 자리만 grep -L 로 한 번에 골라 냄
# (자리마다 cat 을 부르면 이 VM 에서 1분 가까이 걸림)
for f in \$(grep -L '^0000:0000:0000:0000:0000:0000:0000:0000\$' \$D/gids/* 2>/dev/null); do
  i=\${f##*/}
  echo \"\$i|\$(cat \$f 2>/dev/null)|\$(cat \$D/gid_attrs/types/\$i 2>/dev/null)\"
done
echo '###TRANSPORT'
ibv_devinfo -d rxe0 2>/dev/null | grep -E 'transport:|link_layer:'
echo '###PING'
ping -c 2 -W 2 $2 >/dev/null 2>&1 && echo OK || echo NG
" 2>/dev/null | tr -d '\r'
}

# 모아 온 글에서 ###이름 구간만 꺼냄
sect() { awk -v s="###$2" '$0==s{f=1;next} /^###/{f=0} f' <<<"$1"; }

echo "===== lab5 Soft-RoCE 검사 ====="

# 먼저 두 VM 에서 한 번씩 정보를 모아 옴
for n in $VM_NAMES; do
  peer="$(peer_of "$n")"
  if vm_running "$n"; then
    RUNNING[$n]=1
    DATA[$n]="$(collect "$n" "${IP[$peer]}")"
  else
    RUNNING[$n]=0
    DATA[$n]=""
  fi
done

############################################################
echo "1) 두 VM 이 켜져 있고 내부망(${RDMA_NET}.0/${RDMA_PREFIX})으로 서로 보이는가"
for n in $VM_NAMES; do
  peer="$(peer_of "$n")"
  peer_ip="${IP[$peer]}"
  data="${DATA[$n]}"
  if [ "${RUNNING[$n]}" != 1 ]; then
    bad "$n VM 이 꺼져 있음" "./reset.sh 로 처음 상태로 되돌리세요"
  elif [ -z "$data" ]; then
    bad "$n 에 SSH 로 못 들어감" "VM 이 뜨는 중일 수 있음. 1분 뒤 다시 하거나 ./reset.sh 를 쓰세요"
  elif [ "$(sect "$data" PING)" = "OK" ]; then
    ok "$n -> $peer_ip 내부망 통신 정상"
  else
    bad "$n -> $peer_ip 내부망 ping 이 안 됨" \
        "내부망 랜카드 선이 빠졌는지 확인: VBoxManage controlvm $n setlinkstate2 on"
  fi
done

############################################################
echo "2) RDMA 장치 rxe0 이 켜져 있고 내부망 랜카드에 붙었는가"
DEV_OK=1
for n in $VM_NAMES; do
  data="${DATA[$n]}"
  myip="${IP[$n]}"
  NETDEV[$n]=""
  if [ -z "$data" ]; then
    bad "$n 에 들어갈 수 없어 장치를 보지 못함" "1번 항목을 먼저 고치세요"
    DEV_OK=0
    continue
  fi
  # 내부망 주소를 달고 있는 랜카드 이름을 VM 안에서 찾음 (enp0s8 로 못 박지 않음)
  netdev="$(sect "$data" IP | grep " ${myip}/" | awk '{print $2}' | head -1)"
  NETDEV[$n]="$netdev"
  line="$(sect "$data" RDMA | grep '^link rxe0/')"
  # "state ACTIVE physical_state LINK_UP" 에서 홀로 선 state 뒤의 낱말만 집음
  state="$(awk '{for(i=1;i<=NF;i++) if($i=="state"){print $(i+1); exit}}' <<<"$line")"
  bound="$(awk '{for(i=1;i<=NF;i++) if($i=="netdev"){print $(i+1); exit}}' <<<"$line")"
  if [ -z "$netdev" ]; then
    bad "$n: 내부망 주소 $myip 를 가진 랜카드가 없음" \
        "VM 안에서 'ip -4 addr show' 로 확인. 내부망 랜카드 선이 빠졌을 수 있음"
    DEV_OK=0
  elif [ -z "$line" ]; then
    bad "$n: RDMA 장치 rxe0 이 없음" \
        "VM 안에서 'sudo rdma link add rxe0 type rxe netdev $netdev' 또는 'sudo systemctl restart lab5-rxe'"
    DEV_OK=0
  elif [ "$state" != "ACTIVE" ]; then
    bad "$n: rxe0 상태가 $state 임 (ACTIVE 이어야 함)" \
        "붙어 있는 랜카드($bound)가 살아 있는지 'ip link show $bound' 로 확인"
    DEV_OK=0
  elif [ "$bound" != "$netdev" ]; then
    bad "$n: rxe0 이 $bound 에 붙어 있음 (내부망 랜카드 $netdev 이어야 함)" \
        "VM 안에서 'sudo rdma link delete rxe0 && sudo rdma link add rxe0 type rxe netdev $netdev'"
    DEV_OK=0
  else
    ok "$n: rxe0 이 ACTIVE 이고 내부망 랜카드 $netdev 에 붙음"
  fi
done

############################################################
echo "3) rxe0 의 GID 표에 내부망 IP 를 담은 RoCEv2 자리가 있는가"
for n in $VM_NAMES; do
  data="${DATA[$n]}"
  myip="${IP[$n]}"
  want="$(ip_to_gid "$myip")"
  GIDIDX[$n]=1
  tbl="$(sect "$data" GID | grep '|')"
  idx="$(awk -F'|' -v w="$want" '$2==w && $3=="RoCE v2" {print $1; exit}' <<<"$tbl")"
  shown="$(awk -F'|' '$2 != "0000:0000:0000:0000:0000:0000:0000:0000" && $2 != "" {printf "%s=%s(%s) ", $1, $2, $3}' <<<"$tbl")"
  tr_="$(sect "$data" TRANSPORT | tr -s ' \t' ' ' | tr '\n' ' ')"
  if [ -z "$tbl" ]; then
    bad "$n: rxe0 의 GID 표를 읽지 못함 (장치가 없음)" "2번 항목을 먼저 고치세요"
  elif [ -n "$idx" ]; then
    GIDIDX[$n]="$idx"
    ok "$n: GID ${idx}번이 RoCE v2 이고 내부망 주소 $myip 를 담음 ($want)"
  else
    bad "$n: 내부망 주소 $myip 를 담은 RoCE v2 GID 가 없음" \
        "지금 표: ${shown:-없음} / 장치:${tr_:- 모름}. RoCE 가 아닌 다른 방식(iWARP 등)으로 만든 장치일 수 있음. 'sudo rdma link delete rxe0' 뒤 'type rxe' 로 다시 만드세요"
  fi
done

############################################################
CLI_NETDEV="${NETDEV[$CLI]}"
: "${CLI_NETDEV:=enp0s8}"

RUN=1
[ "$DEV_OK" = 1 ] || RUN=0

if [ "$RUN" = 1 ]; then
  # 패킷 먼저 잡기 시작 (손님 VM 의 내부망 랜카드에서 UDP 4791 만 봄).
  # sudo 가 stdbuf 의 LD_PRELOAD 를 지우므로 tcpdump 자신의 -l(줄 단위 출력)을 씀
  ( vm_ssh "$CLI" "sudo timeout 25 tcpdump -l -ni $CLI_NETDEV -c 14 udp port 4791" ) >"$TMP/dump.txt" 2>/dev/null &
  DUMP_PID=$!
  sleep 3
  # 서버를 ssh 한 개로 통째로 띄움. ssh 안에서 & 로 뒤에 띄우면 뜨지 않음 (지피니 실측).
  # 시험 도구로 rping 을 쓰는 까닭: rping 은 주소로 상대를 찾는 RDMA CM 을 거치므로
  # Soft-RoCE 가 아닌 다른 RDMA 방식(iWARP 흉내 siw 등)으로 바꿔치기해도 통신 자체는 성공함.
  # 그래서 "통신은 되는데 RoCEv2 가 아닌" 경우를 5번 항목이 따로 가려낼 수 있음
  # pkill 은 반드시 -x(이름이 딱 rping 인 것)로 씀. -f 로 쓰면 이 명령을 실어 나르는 껍데기 자신이 걸려 죽음
  ( vm_ssh "$SRV" "sudo pkill -x rping >/dev/null 2>&1; timeout 30 stdbuf -o0 -e0 rping -s -a $SRV_IP -C 5 -v -S 64" ) >"$TMP/srv.txt" 2>&1 &
  SRV_PID=$!
  sleep 4
  # 손님. 횟수는 반드시 작게 씀 (-C 5). 큰 값은 이 PC 에서 오래 걸림
  vm_ssh "$CLI" "sudo pkill -x rping >/dev/null 2>&1; timeout 25 stdbuf -o0 -e0 rping -c -a $SRV_IP -C 5 -v -S 64" >"$TMP/cli.txt" 2>&1
  CLI_RC=$?
  # 양쪽 rping 을 반드시 끝냄. 서버는 손님이 끊어도 다음 손님을 기다리고,
  # 살아 있는 rping 을 둔 채로 rxe0 을 지우면 VM 커널이 통째로 죽는 것을 봄 (2026-11-23 실측, kernel panic)
  for n in $VM_NAMES; do
    vm_ssh "$n" "sudo pkill -x rping >/dev/null 2>&1; true" >/dev/null 2>&1
  done
  wait $SRV_PID 2>/dev/null
  wait $DUMP_PID 2>/dev/null
else
  CLI_RC=1
  : >"$TMP/cli.txt"; : >"$TMP/srv.txt"; : >"$TMP/dump.txt"
fi

echo "4) RDMA 프로그램이 상대 VM 과 통신하는가 (rping 5회, $CLI -> $SRV $SRV_IP)"
if [ "$RUN" != 1 ]; then
  bad "RDMA 장치가 성하지 않아 통신 시험을 돌리지 않음" "2번 항목을 먼저 고치세요"
else
  # 주고받은 줄(ping data:) 수로 판정함. 이 줄은 RDMA 로 한 번 오간 뒤에야 찍히므로 통신의 증거임.
  # 다섯 줄을 다 받고도 끊는 인사가 늦어 timeout 에 걸리는 일이 있어, 끝코드만으로 판정하지 않음 (2026-11-23 실측)
  pings="$(grep -c '^ping data: rdma-ping-' "$TMP/cli.txt")"
  if [ "${pings:-0}" -lt 5 ]; then
    bad "$CLI -> $SRV($SRV_IP) RDMA 통신 실패 (주고받은 줄 ${pings:-0}개, 5개여야 함. 끝코드 $CLI_RC)" \
        "손님 쪽 마지막 줄: $(tail -1 "$TMP/cli.txt" | tr -d '\r') / 서버 쪽 마지막 줄: $(tail -1 "$TMP/srv.txt" | tr -d '\r')"
  elif [ "$CLI_RC" != 0 ]; then
    ok "$CLI -> $SRV($SRV_IP) rping 으로 ${pings}번 주고받기 성공 (끊는 인사가 늦어 시간 상한에 걸렸으나 자료는 다 오감)"
  else
    ok "$CLI -> $SRV($SRV_IP) rping 으로 ${pings}번 주고받기 성공"
  fi
fi

echo "5) 그 통신이 RoCEv2(UDP 4791)로 내부망을 오가는가"
if [ "$RUN" != 1 ]; then
  bad "RDMA 장치가 성하지 않아 패킷을 잡지 않음" "2번 항목을 먼저 고치세요"
else
  out="$(grep -c "IP ${CLI_IP}\.[0-9]* > ${SRV_IP}\.4791" "$TMP/dump.txt")"
  in_="$(grep -c "IP ${SRV_IP}\.[0-9]* > ${CLI_IP}\.4791" "$TMP/dump.txt")"
  tot="$(grep -c ' > ' "$TMP/dump.txt")"
  trans="$(sect "${DATA[$CLI]}" TRANSPORT | tr -s ' \t' ' ' | tr '\n' ' ')"
  if [ "${tot:-0}" = 0 ]; then
    bad "$CLI 의 $CLI_NETDEV 에서 UDP 4791 패킷을 하나도 잡지 못함 (4번은 통과했더라도 RoCEv2 가 아님)" \
        "RDMA 가 RoCEv2 가 아닌 다른 길(예: iWARP 흉내 siw 의 TCP)로 갔음. 지금 장치:${trans:- 모름} (transport 가 InfiniBand 여야 RoCE 임)"
  elif [ "${out:-0}" = 0 ] || [ "${in_:-0}" = 0 ]; then
    bad "UDP 4791 패킷이 한쪽으로만 오감 (${CLI_IP}->${SRV_IP} ${out}개, ${SRV_IP}->${CLI_IP} ${in_}개)" \
        "두 VM 사이가 아니라 다른 상대와 주고받았을 수 있음. 4번 항목의 주소를 확인하세요"
  else
    ok "${CLI_IP} <-> ${SRV_IP} 사이에서 UDP 4791 패킷 ${tot}개 잡음 (보냄 ${out}개, 받음 ${in_}개)"
  fi
fi

echo
if [ $fail = 0 ]; then
  echo "결과: 모두 통과"
else
  echo "결과: 실패 항목 있음. 두 번 해도 안 되면 ./reset.sh 로 처음 상태로 되돌리세요"
fi
exit $fail
