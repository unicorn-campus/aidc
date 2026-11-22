#!/usr/bin/env bash
# lab5 VM 끄기와 지우기. WSL 안에서 실행함
#
#   ./vm-down.sh           # 두 VM 을 끄기만 함 (다음 수업에 그대로 다시 켤 수 있음)
#   ./vm-down.sh --delete  # 두 VM 을 지움 (디스크 파일까지 없앰)
#   ./vm-down.sh rdma1     # 한 대만

. "$(cd "$(dirname "$0")" && pwd)/_common.sh"

DELETE=0
TARGETS=""
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE=1 ;;
    -*) die "모르는 옵션: $arg" ;;
    *)  TARGETS="$TARGETS $arg" ;;
  esac
done
[ -n "$TARGETS" ] || TARGETS="$VM_NAMES"

[ -x "$VBM" ] || die "VBoxManage 를 찾지 못함: $VBM"

for n in $TARGETS; do
  if ! vm_exists "$n"; then
    say "$n 은 없음. 건너뜀"
    continue
  fi
  if vm_running "$n"; then
    say "$n 끄는 중"
    "$VBM" controlvm "$n" acpipowerbutton >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      vm_running "$n" || break
      sleep 2
    done
    if vm_running "$n"; then
      say "$n 이 곱게 꺼지지 않아 전원을 내림"
      "$VBM" controlvm "$n" poweroff >/dev/null 2>&1 || true
      sleep 3
    fi
  fi
  if [ "$DELETE" = "1" ]; then
    say "$n 지우는 중"
    "$VBM" unregistervm "$n" --delete >/dev/null
    rm -rf "${VMBASE_WSL:?}/$n"
  fi
done

say "끝. 남은 VM:"
"$VBM" list vms | tr -d '\r'
