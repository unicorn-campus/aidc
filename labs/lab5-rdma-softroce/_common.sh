#!/usr/bin/env bash
# lab5 스크립트가 함께 쓰는 길잡이 함수 모음. 직접 실행하지 않고 source 로 읽음

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LAB_DIR/../.." && pwd)"

# shellcheck source=lab5.env
. "$LAB_DIR/lab5.env"

# VirtualBox 관리 명령 (WSL 안에서 Windows 쪽 실행 파일을 그대로 부름)
VBM="/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"

OVA_WSL="$ROOT_DIR/$OVA_REL"
KEY_WSL="$ROOT_DIR/$KEY_REL"
VMBASE_WSL="$ROOT_DIR/$VMBASE_REL"

# WSL 안에서만 쓰는 SSH 키 사본. /mnt/c 의 파일은 권한이 777 로 보여 ssh 가 거부하므로 600 으로 복사해 씀
KEY_RUN="$HOME/.ssh/aidc-lab5"

# VM 은 Windows 쪽 VirtualBox 가 띄우므로, WSL 에서 SSH 로 붙으려면 Windows 호스트 주소가 필요함.
# WSL2 의 기본 게이트웨이가 곧 Windows 호스트임
WIN_HOST="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
: "${WIN_HOST:=127.0.0.1}"

die() { echo "[lab5] 멈춤: $*" >&2; exit 1; }
say() { echo "[lab5] $*"; }

# 준비물 확인
require_env() {
  [ -x "$VBM" ] || die "VBoxManage 를 찾지 못함: $VBM"
  command -v wslpath >/dev/null || die "wslpath 가 없음. 이 스크립트는 WSL 안에서 실행함"
  [ -f "$OVA_WSL" ] || die "원본 이미지가 없음: $OVA_WSL"
  [ -f "$KEY_WSL" ] || die "SSH 키가 없음: $KEY_WSL (ssh-keygen -t ed25519 -N '' -f $KEY_WSL)"
}

# .cache 의 키를 WSL 홈으로 600 권한으로 복사
prepare_key() {
  mkdir -p "$HOME/.ssh"
  cp "$KEY_WSL" "$KEY_RUN"
  chmod 600 "$KEY_RUN"
}

# VM 이름 -> lab5.env 의 VM_SPEC_* 값을 읽어 변수로 풀어 놓음
load_spec() {
  local name="$1" spec
  spec="$(eval "echo \"\${VM_SPEC_${name}:-}\"")"
  [ -n "$spec" ] || die "lab5.env 에 VM_SPEC_${name} 이 없음"
  VM_HOSTNUM="$(echo "$spec" | cut -d'|' -f1)"
  VM_MAC_NAT="$(echo "$spec" | cut -d'|' -f2)"
  VM_MAC_INT="$(echo "$spec" | cut -d'|' -f3)"
  VM_SSH_PORT="$(echo "$spec" | cut -d'|' -f4)"
  VM_IP="${RDMA_NET}.${VM_HOSTNUM}"
}

vm_exists() {
  "$VBM" list vms 2>/dev/null | tr -d '\r' | grep -q "^\"$1\" "
}

vm_running() {
  "$VBM" list runningvms 2>/dev/null | tr -d '\r' | grep -q "^\"$1\" "
}

# WSL 에서 VM 으로 ssh. 첫 인자는 VM 이름, 나머지는 VM 안에서 돌릴 명령
vm_ssh() {
  local name="$1"; shift
  load_spec "$name"
  ssh -i "$KEY_RUN" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=5 \
      -p "$VM_SSH_PORT" "${VM_USER}@${WIN_HOST}" "$@"
}

# VM 이 SSH 를 받을 때까지 기다림. 둘째 인자는 최대 기다릴 초.
# 시간 안에 못 받으면 멈추지 않고 1 을 돌려줌 (부르는 쪽이 다시 켜 볼 수 있게)
wait_ssh() {
  local name="$1" limit="${2:-300}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    if vm_ssh "$name" true >/dev/null 2>&1; then
      say "$name SSH 열림 (${waited}초)"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}
