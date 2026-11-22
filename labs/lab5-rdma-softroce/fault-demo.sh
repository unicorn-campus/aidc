#!/usr/bin/env bash
# 검사 스크립트가 고장을 실제로 잡는지 시험함 (강사 고장 연습용으로도 씀)
# 고장을 하나씩 내고 ./check.sh 를 돌린 뒤 바로 되돌림. 마지막에 모두 통과하는지 확인함
#
#   ./fault-demo.sh         # 고장 네 가지를 차례로 냄
#   ./fault-demo.sh 3       # 세 번째 고장만 냄
#
# 고장 목록
#   1 RDMA 장치를 지움          rdma1 의 rxe0 을 지움
#   2 내부망 선을 뽑음          rdma2 의 내부망 랜카드 선을 끊음
#   3 엉뚱한 랜카드에 붙임      rdma1 의 rxe0 을 NAT 랜카드(enp0s3)에 붙임
#   4 편법: RoCE 가 아닌 것으로 바꿔치기
#            양쪽 rxe0 을 지우고 같은 이름으로 iWARP 흉내(siw) 장치를 만듦.
#            RDMA 통신(4번 항목)은 그대로 되지만 자료가 UDP 4791 이 아니라 TCP 로 감

cd "$(dirname "$0")" || exit 1
. ./_common.sh
set +e +u +o pipefail

[ -x "$VBM" ] || die "VBoxManage 를 찾지 못함: $VBM"
[ -f "$KEY_RUN" ] || prepare_key

WANT="${1:-all}"

declare -A IP
for n in $VM_NAMES; do load_spec "$n"; IP[$n]="$VM_IP"; done
A="$(echo $VM_NAMES | awk '{print $1}')"   # rdma1
B="$(echo $VM_NAMES | awk '{print $2}')"   # rdma2

# VM 안에서 내부망 주소를 단 랜카드 이름을 찾음 (enp0s8 로 못 박지 않음)
netdev_of() {
  vm_ssh "$1" "ip -o -4 addr show | grep ' ${IP[$1]}/' | awk '{print \$2}' | head -1" 2>/dev/null | tr -d '\r'
}

# RDMA 장치를 지우기 전에 반드시 부름.
# rping 같은 RDMA 프로그램이 살아 있는 채로 rxe0 을 지우면 VM 커널이 통째로 죽음
# (2026-11-23 실측: rdma1 에서 kernel panic 이 나 VM 이 멎었음)
quiet_rdma() {
  local n
  for n in $VM_NAMES; do
    vm_ssh "$n" "sudo pkill -x rping >/dev/null 2>&1; sudo pkill -x ibv_rc_pingpong >/dev/null 2>&1; true" >/dev/null 2>&1
  done
  sleep 2
}

# 두 VM 의 Soft-RoCE 를 원래대로 되돌림 (지우고 지피니의 설정 스크립트를 다시 돌림)
restore_rxe() {
  local n
  quiet_rdma
  for n in $VM_NAMES; do
    vm_ssh "$n" "sudo rdma link delete rxe0 >/dev/null 2>&1; sudo modprobe -r siw >/dev/null 2>&1; true" >/dev/null 2>&1
    vm_ssh "$n" "sudo bash -s" < ./cfg/setup-rxe.sh >/dev/null 2>&1
  done
}

hr() { echo; echo "##### $*"; }

############################################################
hr "정상 상태 확인"
./check.sh

############################################################
if [ "$WANT" = all ] || [ "$WANT" = 1 ]; then
hr "고장1: $A 의 RDMA 장치를 지움 (sudo rdma link delete rxe0)"
echo "  [기대] 2번 실패(장치 없음), 그에 따라 3 ~ 5번도 실패. 내부망 ping(1번)은 통과"
quiet_rdma
vm_ssh "$A" "sudo rdma link delete rxe0" >/dev/null 2>&1
echo "  지금 $A 의 rdma link: '$(vm_ssh "$A" "rdma link show" 2>/dev/null | tr -d '\r')' (비어 있어야 함)"
./check.sh
echo "  -- 되돌리는 중 (sudo systemctl restart lab5-rxe) --"
vm_ssh "$A" "sudo systemctl restart lab5-rxe" >/dev/null 2>&1
fi

############################################################
if [ "$WANT" = all ] || [ "$WANT" = 2 ]; then
hr "고장2: $B 의 내부망 랜카드 선을 뽑음 (setlinkstate2 off)"
echo "  [기대] 1번 실패(내부망 ping 안 됨)와 함께 4 ~ 5번 실패"
"$VBM" controlvm "$B" setlinkstate2 off >/dev/null 2>&1
sleep 5
./check.sh
echo "  -- 되돌리는 중 (setlinkstate2 on 뒤 Soft-RoCE 다시 붙임) --"
"$VBM" controlvm "$B" setlinkstate2 on >/dev/null 2>&1
sleep 10
restore_rxe
fi

############################################################
if [ "$WANT" = all ] || [ "$WANT" = 3 ]; then
hr "고장3: $A 의 rxe0 을 엉뚱한 랜카드(NAT 쪽)에 붙임"
echo "  [기대] 내부망 ping(1번)은 통과하지만 2번이 'netdev 가 다름'으로 잡아냄"
NAT_DEV="$(vm_ssh "$A" "ip -o -4 addr show | grep -v ' lo ' | grep -v ' ${IP[$A]}/' | awk '{print \$2}' | head -1" 2>/dev/null | tr -d '\r')"
: "${NAT_DEV:=enp0s3}"
quiet_rdma
vm_ssh "$A" "sudo rdma link delete rxe0 >/dev/null 2>&1; sudo rdma link add rxe0 type rxe netdev $NAT_DEV" >/dev/null 2>&1
echo "  지금 $A 의 rdma link: $(vm_ssh "$A" "rdma link show" 2>/dev/null | tr -d '\r')"
./check.sh
echo "  -- 되돌리는 중 --"
restore_rxe
fi

############################################################
if [ "$WANT" = all ] || [ "$WANT" = 4 ]; then
hr "고장4(편법): 양쪽 rxe0 을 RoCE 가 아닌 iWARP 흉내(siw) 장치로 바꿔치기"
echo "  [기대] 이름도 rxe0, 붙은 랜카드도 내부망이라 2번은 통과하고 RDMA 통신(4번)도 성공하지만,"
echo "         자료가 UDP 4791 이 아니라 TCP 로 가므로 3번과 5번이 잡아냄"
quiet_rdma
for n in $VM_NAMES; do
  nd="$(netdev_of "$n")"
  vm_ssh "$n" "sudo rdma link delete rxe0 >/dev/null 2>&1; sudo modprobe siw && sudo rdma link add rxe0 type siw netdev $nd" >/dev/null 2>&1
  echo "  $n: $(vm_ssh "$n" "rdma link show; ibv_devinfo -d rxe0 2>/dev/null | grep transport:" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
done

# 바꿔치기해도 통신 자체는 되는지, 그리고 그 자료가 어느 길로 가는지 눈으로 보여 줌
echo "  -- 통신이 되는지, 어느 길로 가는지 따로 봄 --"
BDEV="$(netdev_of "$B")"
TMPD="$(mktemp -d)"
( vm_ssh "$B" "sudo timeout 25 tcpdump -l -nqi $BDEV -c 20 '(udp port 4791) or (tcp and not port 22)'" ) >"$TMPD/d.txt" 2>/dev/null &
DP=$!
sleep 3
( vm_ssh "$A" "sudo pkill -x rping >/dev/null 2>&1; timeout 20 stdbuf -o0 -e0 rping -s -a ${IP[$A]} -C 5 -v -S 64" ) >"$TMPD/s.txt" 2>&1 &
SP=$!
sleep 4
vm_ssh "$B" "timeout 20 stdbuf -o0 -e0 rping -c -a ${IP[$A]} -C 5 -v -S 64" >"$TMPD/c.txt" 2>&1
CRC=$?
CLINES="$(grep -c '^ping data: rdma-ping-' "$TMPD/c.txt")"
echo "  rping 손님 끝코드=$CRC / 주고받은 줄 ${CLINES}개 (0 이 아니면 통신이 된 것임)"
vm_ssh "$A" "sudo pkill -x rping >/dev/null 2>&1; true" >/dev/null 2>&1
wait $SP 2>/dev/null; wait $DP 2>/dev/null
echo "  잡힌 패킷 중 UDP 4791: $(grep -c '\.4791' "$TMPD/d.txt")개 / TCP: $(grep -c 'tcp' "$TMPD/d.txt")개"
echo "  보기: $(head -1 "$TMPD/d.txt" | tr -d '\r')"
rm -rf "$TMPD"

./check.sh
echo "  -- 되돌리는 중 --"
restore_rxe
fi

############################################################
hr "되돌린 뒤 확인"
./check.sh
RC=$?
echo
if [ $RC = 0 ]; then
  echo "고장 연습 끝. 모든 고장을 되돌렸고 검사가 다시 통과함"
else
  echo "고장 연습 끝. 검사가 아직 통과하지 않음. ./reset.sh 로 처음 상태로 되돌리세요"
fi
exit $RC
