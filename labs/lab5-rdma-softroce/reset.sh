#!/usr/bin/env bash
# lab5 를 처음 상태로 되돌림. 깨지면 고치지 않고 통째로 되돌림
#
#   ./reset.sh
#
# 하는 일
#   1) 두 VM 의 전원을 내림            2) 스냅샷 'clean' 으로 되돌림
#   3) 다시 켜고 SSH 가 열릴 때까지 기다림  4) Soft-RoCE(rxe0) 를 다시 붙임
#   5) ./check.sh 를 돌려 결과를 보여 줌
#
# 처음부터 다시 만드는 ./vm-up.sh 는 이 PC 에서 약 872초(14분 32초)가 걸려 수업 중에는 쓸 수 없음.
# 그래서 되돌리기는 스냅샷 방식을 씀. 스냅샷은 ./snapshot-clean.sh 로 수업 전에 한 번만 만들어 둠

cd "$(dirname "$0")" || exit 1
. ./_common.sh
set +e +u +o pipefail

SNAP="${LAB5_SNAPSHOT:-clean}"

[ -x "$VBM" ] || die "VBoxManage 를 찾지 못함: $VBM"
[ -f "$KEY_RUN" ] || prepare_key

snap_exists() {
  "$VBM" snapshot "$1" list 2>/dev/null | tr -d '\r' | grep -q "Name: ${SNAP} "
}

wait_off() {
  local n="$1" i
  for i in $(seq 1 30); do
    vm_running "$n" || return 0
    sleep 2
  done
  return 1
}

for n in $VM_NAMES; do
  vm_exists "$n"  || die "$n VM 이 없음. 먼저 ./vm-up.sh 로 만드세요"
  snap_exists "$n" || die "$n 에 '$SNAP' 스냅샷이 없음. 먼저 ./snapshot-clean.sh 를 한 번 돌리세요"
done

START_TS=$(date +%s)

# 1. 전원 내리기. 어차피 버릴 상태이므로 곱게 끄지 않고 바로 내림 (빠름)
for n in $VM_NAMES; do
  if vm_running "$n"; then
    say "$n 전원 내리는 중"
    "$VBM" controlvm "$n" poweroff >/dev/null 2>&1
  fi
done
for n in $VM_NAMES; do
  wait_off "$n" || die "$n 이 꺼지지 않음. VirtualBox 창을 확인하세요"
done

# 2. 스냅샷으로 되돌리기
for n in $VM_NAMES; do
  "$VBM" snapshot "$n" restore "$SNAP" >/dev/null || die "$n 을 '$SNAP' 으로 되돌리지 못함"
  say "$n 을 '$SNAP' 스냅샷으로 되돌림"
done

# 3. 다시 켜고 기다리기. 두 대를 먼저 다 켜 두고 그 다음에 둘을 같이 지켜봄
#
#    이 PC 는 WSL2 와 Docker Desktop 이 하드웨어 가속을 이미 잡고 있어 VirtualBox 가 느린 방식으로 돎.
#    그래서 부팅이 20초에 끝나기도 하고, 호스트가 바쁘면 5분을 넘기기도 함(2026-11-23 실측).
#    시간만 보고 전원을 껐다 켜면 잘 뜨고 있던 VM 을 끊어 버려 오히려 더 느려짐.
#    그래서 "부팅 메시지 파일이 자라고 있는가"를 봄.
#      - 파일이 자라는 중이면 느려도 기다림
#      - STALL_SEC 초 동안 한 글자도 안 늘면 진짜 멈춘 것으로 보고 전원을 껐다 켬
#        (지피니가 적은 initramfs "Loading essential drivers ..." 멈춤)
#      - 아무리 자라도 BOOT_MAX 초를 넘기면 한 번 껐다 켬
STALL_SEC="${LAB5_STALL_SEC:-70}"
BOOT_MAX="${LAB5_BOOT_MAX:-420}"

serial_size() {
  stat -c %s "$VMBASE_WSL/$1/serial.log" 2>/dev/null || echo 0
}

for n in $VM_NAMES; do
  "$VBM" startvm "$n" --type headless >/dev/null || die "$n 을 켜지 못함"
  say "$n 켬"
done

pending="$VM_NAMES"
declare -A LASTSZ STILLSEC
for n in $VM_NAMES; do LASTSZ[$n]="$(serial_size "$n")"; STILLSEC[$n]=0; done

for round in 1 2 3; do
  waited=0
  while [ -n "$pending" ] && [ "$waited" -lt "$BOOT_MAX" ]; do
    still=""
    for n in $pending; do
      if vm_ssh "$n" true >/dev/null 2>&1; then
        say "$n SSH 열림 (${round}번째 켬, ${waited}초)"
        continue
      fi
      sz="$(serial_size "$n")"
      if [ "$sz" != "${LASTSZ[$n]}" ]; then
        LASTSZ[$n]="$sz"
        STILLSEC[$n]=0            # 부팅 메시지가 늘고 있음. 느릴 뿐이니 더 기다림
      else
        STILLSEC[$n]=$(( STILLSEC[$n] + 5 ))
      fi
      still="$still $n"
    done
    pending="$(echo $still)"
    [ -n "$pending" ] || break

    # 메시지가 STALL_SEC 초째 안 늘어난 VM 이 있으면 더 기다리지 않고 껐다 켬
    stuck=""
    for n in $pending; do
      [ "${STILLSEC[$n]}" -ge "$STALL_SEC" ] && stuck="$stuck $n"
    done
    [ -z "$stuck" ] || break

    sleep 5
    waited=$((waited + 5))
  done
  [ -n "$pending" ] || break

  for n in $pending; do
    if [ "${STILLSEC[$n]}" -ge "$STALL_SEC" ]; then
      say "$n 이 ${STILLSEC[$n]}초째 부팅 메시지가 늘지 않음(멈춘 것으로 봄). 전원을 껐다 켬"
    else
      say "$n 이 ${BOOT_MAX}초를 넘겨도 SSH 를 열지 않음. 전원을 껐다 켬"
    fi
    "$VBM" controlvm "$n" poweroff >/dev/null 2>&1
    STILLSEC[$n]=0
  done
  # 전원을 내린 뒤 VirtualBox 가 그 VM 을 완전히 놓을 때까지 기다림.
  # 곧바로 다시 켜면 아직 안 끝난 VBoxHeadless 가 남아 서로 자원을 다투고, 부팅이 더 느려짐 (2026-11-23 실측)
  for n in $pending; do wait_off "$n" || true; done
  sleep 12
  for n in $pending; do
    "$VBM" startvm "$n" --type headless >/dev/null
    LASTSZ[$n]="$(serial_size "$n")"
  done
done
[ -z "$pending" ] || die "다음 VM 을 띄우지 못함:$pending. 부팅 메시지를 확인: $VMBASE_WSL/<이름>/serial.log"

# 4. Soft-RoCE 다시 붙이기 (지피니의 cfg/setup-rxe.sh 를 그대로 들여보냄)
for n in $VM_NAMES; do
  say "$n Soft-RoCE 설정 중"
  vm_ssh "$n" "sudo bash -s" < ./cfg/setup-rxe.sh >/dev/null 2>&1 \
    || die "$n Soft-RoCE 설정 실패. ./vm-ssh.sh $n 로 들어가 'sudo bash' 로 cfg/setup-rxe.sh 를 돌려 보세요"
done

ELAPSED=$(( $(date +%s) - START_TS ))
say "되돌리기 걸린 시간: ${ELAPSED}초"
echo

# 5. 검사
./check.sh
RC=$?
echo
say "되돌리기 ${ELAPSED}초 + 검사까지 모두 끝남"
exit $RC
