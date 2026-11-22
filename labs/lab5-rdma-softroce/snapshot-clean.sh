#!/usr/bin/env bash
# 수업 전에 강사가 한 번만 돌림. reset.sh 가 되돌아갈 "깨끗한 처음 상태"를 VirtualBox 스냅샷으로 저장함
#
#   ./snapshot-clean.sh           # 스냅샷이 없으면 만듦. 이미 있으면 건너뜀
#   ./snapshot-clean.sh --force   # 있던 스냅샷을 지우고 다시 만듦
#
# 왜 필요한가
#   vm-up.sh 로 처음부터 다시 만들면 이 PC 에서 약 872초(14분 32초)가 걸림. 수업 중에 되돌리기로 쓸 수 없음.
#   그래서 꾸러미가 다 깔린 상태를 스냅샷으로 떠 두고, reset.sh 는 그 스냅샷으로 되돌리기만 함(약 1 ~ 2분)
#
# 스냅샷을 찍는 시점
#   꾸러미(rdma-core, ibverbs-utils, rdmacm-utils, perftest, tcpdump, linux-modules-extra)는 다 깔린 상태,
#   Soft-RoCE 장치(rxe0)와 lab5-rxe 서비스는 걷어 낸 상태.
#   수강생이 'rdma link add' 를 직접 해 보는 것이 이 실습의 알맹이이므로, 되돌린 자리에는 장치가 없어야 함.
#   (reset.sh 는 되돌린 뒤 cfg/setup-rxe.sh 를 한 번 돌려 주므로, 검사까지 바로 통과함)

cd "$(dirname "$0")" || exit 1
. ./_common.sh
set +e +u +o pipefail

SNAP="${LAB5_SNAPSHOT:-clean}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ -x "$VBM" ] || die "VBoxManage 를 찾지 못함: $VBM"
[ -f "$KEY_WSL" ] || die "SSH 키가 없음: $KEY_WSL. 먼저 ./vm-up.sh 로 VM 을 만드세요"
prepare_key

# 그 VM 에 이름이 $SNAP 인 스냅샷이 있는지 봄
snap_exists() {
  "$VBM" snapshot "$1" list 2>/dev/null | tr -d '\r' | grep -q "Name: ${SNAP} "
}

# VM 이 멈출 때까지 기다림 (최대 60초)
wait_off() {
  local n="$1" i
  for i in $(seq 1 30); do
    vm_running "$n" || return 0
    sleep 2
  done
  return 1
}

START_TS=$(date +%s)

for n in $VM_NAMES; do
  vm_exists "$n" || die "$n VM 이 없음. 먼저 ./vm-up.sh 로 만드세요"

  if snap_exists "$n"; then
    if [ "$FORCE" = 0 ]; then
      say "$n 은 이미 '$SNAP' 스냅샷이 있음. 건너뜀 (다시 만들려면 --force)"
      continue
    fi
    say "$n 의 옛 '$SNAP' 스냅샷을 지움"
    "$VBM" snapshot "$n" delete "$SNAP" >/dev/null || die "$n 스냅샷을 지우지 못함"
  fi

  # 1. 켜고 SSH 가 열릴 때까지 기다림
  if ! vm_running "$n"; then
    say "$n 켜는 중"
    "$VBM" startvm "$n" --type headless >/dev/null || die "$n 을 켜지 못함"
  fi
  # 켤 때 가끔 initramfs("Loading essential drivers ...")에서 멈춤. 전원을 껐다 켜면 풀림 (지피니 실측).
  # 다만 호스트가 바쁘면 멈춘 것이 아니라 그냥 느린 것일 때도 있으므로 넉넉히 기다림. 세 번까지 해 봄
  up=0
  for round in 1 2 3; do
    if wait_ssh "$n" "${LAB5_BOOT_MAX:-420}"; then up=1; break; fi
    say "$n 이 ${LAB5_BOOT_MAX:-420}초 안에 SSH 를 열지 않음(첫 부팅에서 멈추는 알려진 문제). 전원을 껐다 켬"
    "$VBM" controlvm "$n" poweroff >/dev/null 2>&1
    sleep 10
    "$VBM" startvm "$n" --type headless >/dev/null
  done
  [ "$up" = 1 ] || die "$n 을 띄우지 못함. 부팅 메시지: $VMBASE_WSL/$n/serial.log"

  # 2. 꾸러미 설치(cloud-init)가 끝날 때까지 기다림
  say "$n cloud-init 끝날 때까지 기다리는 중"
  vm_ssh "$n" "sudo cloud-init status --wait" >/dev/null 2>&1

  # 3. 이 실습에 꼭 필요한 것이 실제로 깔렸는지 확인. 없으면 스냅샷을 떠도 소용없음
  miss=""
  for c in rdma ibv_devices ibv_rc_pingpong rping ib_send_bw tcpdump; do
    vm_ssh "$n" "command -v $c" >/dev/null 2>&1 || miss="$miss $c"
  done
  [ -z "$miss" ] || die "$n 에 다음 명령이 없음:$miss. cloud-init 가 끝났는지 확인하세요"
  vm_ssh "$n" "sudo modprobe rdma_rxe" >/dev/null 2>&1 \
    || die "$n 에서 rdma_rxe 모듈을 올리지 못함. linux-modules-extra-\$(uname -r) 가 깔렸는지 확인하세요"
  say "$n 꾸러미와 rdma_rxe 모듈 확인됨"

  # 4. Soft-RoCE 설정만 걷어 냄 (수강생이 직접 붙여 보도록)
  vm_ssh "$n" "sudo bash -s" <<'EOS' >/dev/null 2>&1
systemctl disable --now lab5-rxe.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/lab5-rxe.service
systemctl daemon-reload
for d in $(rdma link show 2>/dev/null | awk '{print $2}' | cut -d/ -f1); do
  rdma link delete "$d" >/dev/null 2>&1 || true
done
EOS
  left="$(vm_ssh "$n" "rdma link show" 2>/dev/null | tr -d '\r')"
  [ -z "$left" ] || die "$n 에 RDMA 장치가 남아 있음: $left"
  say "$n Soft-RoCE 설정을 걷어 냄 (rdma link 비어 있음)"

  # 5. 곱게 끄기
  say "$n 끄는 중"
  "$VBM" controlvm "$n" acpipowerbutton >/dev/null 2>&1
  if ! wait_off "$n"; then
    say "$n 이 곱게 꺼지지 않아 전원을 내림"
    "$VBM" controlvm "$n" poweroff >/dev/null 2>&1
    sleep 3
  fi

  # 6. 스냅샷 뜨기
  "$VBM" snapshot "$n" take "$SNAP" \
    --description "aidc lab5 처음 상태: 꾸러미 설치 끝, Soft-RoCE 는 안 붙임" >/dev/null \
    || die "$n 스냅샷을 만들지 못함"
  say "$n '$SNAP' 스냅샷 만듦"
done

echo
say "걸린 시간: $(( $(date +%s) - START_TS ))초"
for n in $VM_NAMES; do
  echo "--- $n 스냅샷 ---"
  "$VBM" snapshot "$n" list 2>/dev/null | tr -d '\r'
done
echo
say "이제 ./reset.sh 로 언제든 처음 상태로 되돌릴 수 있음"
