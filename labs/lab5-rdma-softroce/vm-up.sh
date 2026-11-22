#!/usr/bin/env bash
# lab5 VM 만들기. WSL 안에서 실행함
#
#   ./vm-up.sh            # rdma1, rdma2 둘 다 만들고 Soft-RoCE 까지 설정
#   ./vm-up.sh rdma1      # 한 대만 만듦
#   ./vm-up.sh --no-setup # VM 만 만들고 Soft-RoCE 설정은 하지 않음

. "$(cd "$(dirname "$0")" && pwd)/_common.sh"

DO_SETUP=1
TARGETS=""
for arg in "$@"; do
  case "$arg" in
    --no-setup) DO_SETUP=0 ;;
    -*) die "모르는 옵션: $arg" ;;
    *)  TARGETS="$TARGETS $arg" ;;
  esac
done
[ -n "$TARGETS" ] || TARGETS="$VM_NAMES"

require_env
prepare_key
mkdir -p "$VMBASE_WSL"

OVA_WIN="$(wslpath -w "$OVA_WSL")"
VMBASE_WIN="$(wslpath -w "$VMBASE_WSL")"
PUBKEY="$(cat "${KEY_WSL}.pub")"

# 0800275A0101 -> 08:00:27:5a:01:01 (netplan 은 콜론이 든 소문자 MAC 을 씀)
mac_colon() {
  echo "$1" | tr 'A-Z' 'a-z' | sed 's/../&:/g; s/:$//'
}

# /etc/hosts 에 넣을 줄 (모든 VM 의 내부망 주소)
build_hosts_block() {
  local n
  for n in $VM_NAMES; do
    load_spec "$n"
    echo "${RDMA_NET}.${VM_HOSTNUM} ${n}"
  done
}

# 모든 VM 의 "내부망주소 이름" 줄. user-data 의 @@HOSTS@@ 자리에 통째로 들어감
HOSTS_BLOCK="$(build_hosts_block | sed 's/^/      /')"

make_seed_iso() {
  local name="$1" workdir seed_wsl
  load_spec "$name"
  workdir="$(mktemp -d)"
  seed_wsl="$VMBASE_WSL/$name/seed.iso"
  mkdir -p "$VMBASE_WSL/$name"

  sed -e "s|@@VMNAME@@|$name|g" \
      -e "s|@@VMUSER@@|$VM_USER|g" \
      -e "s|@@PUBKEY@@|$PUBKEY|g" \
      "$LAB_DIR/cloud-init/user-data.tmpl" > "$workdir/user-data"
  # 여러 줄짜리 hosts 블록은 sed 한 줄로 못 넣으므로 awk 로 바꿔 넣음
  awk -v block="$HOSTS_BLOCK" \
      '{ if ($0 ~ /@@HOSTS@@/) { print block } else { print } }' \
      "$workdir/user-data" > "$workdir/user-data.2" && mv "$workdir/user-data.2" "$workdir/user-data"

  sed -e "s|@@VMNAME@@|$name|g" \
      "$LAB_DIR/cloud-init/meta-data.tmpl" > "$workdir/meta-data"

  sed -e "s|@@MAC_NAT@@|$(mac_colon "$VM_MAC_NAT")|g" \
      -e "s|@@MAC_INT@@|$(mac_colon "$VM_MAC_INT")|g" \
      -e "s|@@RDMA_IP@@|$VM_IP|g" \
      -e "s|@@RDMA_PREFIX@@|$RDMA_PREFIX|g" \
      "$LAB_DIR/cloud-init/network-config.tmpl" > "$workdir/network-config"

  cloud-localds -v \
    --network-config="$workdir/network-config" \
    "$seed_wsl" "$workdir/user-data" "$workdir/meta-data" >/dev/null
  rm -rf "$workdir"
  say "$name 시드 ISO 만듦: $seed_wsl"
}

create_vm() {
  local name="$1"
  load_spec "$name"

  if vm_exists "$name"; then
    say "$name 은 이미 있음. 건너뜀 (지우려면 ./vm-down.sh $name)"
    return 0
  fi

  say "$name 만드는 중 (CPU ${VM_CPUS}개, 메모리 ${VM_MEM_MB}MB, 내부망 ${VM_IP}/${RDMA_PREFIX})"
  "$VBM" import "$OVA_WIN" \
    --vsys 0 --vmname "$name" \
    --cpus "$VM_CPUS" --memory "$VM_MEM_MB" \
    --basefolder "$VMBASE_WIN" >/dev/null

  # 랜카드 1: 바깥 인터넷용 NAT (apt 로 꾸러미를 받기 위함) + 호스트 포트로 SSH 를 넘겨 받음
  # 랜카드 2: 두 VM 만 쓰는 전용 내부망. RDMA 트래픽은 여기로만 다님
  "$VBM" modifyvm "$name" \
    --nic1 nat --nictype1 virtio --macaddress1 "$VM_MAC_NAT" --cableconnected1 on \
    --nic2 intnet --intnet2 "$INTNET_NAME" --nictype2 virtio \
    --macaddress2 "$VM_MAC_INT" --cableconnected2 on \
    --natpf1 "ssh,tcp,,${VM_SSH_PORT},,22" \
    --boot1 disk --boot2 dvd --boot3 none --boot4 none \
    --vram 16 --audio-driver none >/dev/null

  # 부팅 메시지를 파일로 받음. VirtualBox 화면은 커널이 직렬 콘솔로 넘어가는 순간 멈춘 것처럼 보이므로,
  # 무엇이 어디까지 됐는지는 이 파일로 봄
  "$VBM" modifyvm "$name" --uart1 0x3F8 4 \
    --uartmode1 file "$(wslpath -w "$VMBASE_WSL/$name/serial.log")" >/dev/null

  make_seed_iso "$name"
  local seed_win
  seed_win="$(wslpath -w "$VMBASE_WSL/$name/seed.iso")"

  # 시드 ISO 는 따로 만든 SATA 자리에 꽂음 (원본 OVA 의 IDE 자리와 부딪히지 않게)
  "$VBM" storagectl "$name" --name "lab5-seed" --add sata --controller IntelAhci --portcount 1 >/dev/null
  "$VBM" storageattach "$name" --storagectl "lab5-seed" \
    --port 0 --device 0 --type dvddrive --medium "$seed_win" >/dev/null
}

# VM 을 켜고 SSH 가 열릴 때까지 기다림. 안 열리면 전원을 껐다 켜고 다시 시도함.
# 이 PC 에서는 이미지를 들여온 뒤 처음 켤 때 initramfs("Loading essential drivers")에서 멈추는 일이 잦음.
# 전원을 껐다 켜면 풀림 (2026-11-23 rdma1, rdma2 양쪽에서 실측)
boot_vm() {
  local name="$1" attempt=1 limit=210
  while [ "$attempt" -le 3 ]; do
    if ! vm_running "$name"; then
      say "$name 켜는 중 (시도 ${attempt}/3, 화면 없이 뒤에서 뜸)"
      "$VBM" startvm "$name" --type headless >/dev/null
    fi
    if wait_ssh "$name" "$limit"; then
      return 0
    fi
    say "$name 이 ${limit}초 안에 SSH 를 열지 않음. 전원을 껐다 켬"
    "$VBM" controlvm "$name" poweroff >/dev/null 2>&1 || true
    sleep 8
    attempt=$((attempt + 1))
  done
  die "$name 을 띄우지 못함. 부팅 메시지를 확인: $VMBASE_WSL/$name/serial.log"
}

setup_vm() {
  local name="$1"
  say "$name cloud-init 끝날 때까지 기다리는 중 (첫 부팅은 꾸러미를 받느라 몇 분 걸림)"
  vm_ssh "$name" "sudo cloud-init status --wait" || true
  say "$name Soft-RoCE 설정 시작"
  vm_ssh "$name" "sudo bash -s" < "$LAB_DIR/cfg/setup-rxe.sh"
}

START_TS=$(date +%s)

for n in $TARGETS; do
  create_vm "$n"
done

# 먼저 모두 켜 두고(같이 뜨게), 그 다음 한 대씩 SSH 를 기다림
for n in $TARGETS; do
  vm_running "$n" || "$VBM" startvm "$n" --type headless >/dev/null
  say "$n 켬"
done

for n in $TARGETS; do
  boot_vm "$n"
done

if [ "$DO_SETUP" = "1" ]; then
  for n in $TARGETS; do
    setup_vm "$n"
  done
fi

say "걸린 시간: $(( $(date +%s) - START_TS ))초"
say "들어가 보기: ./vm-ssh.sh rdma1"
