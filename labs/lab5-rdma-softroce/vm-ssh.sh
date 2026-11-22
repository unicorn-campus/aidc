#!/usr/bin/env bash
# lab5 VM 에 들어가기. WSL 안에서 실행함
#
#   ./vm-ssh.sh rdma1                      # 대화형으로 들어감
#   ./vm-ssh.sh rdma1 rdma link show       # 명령 하나만 돌리고 나옴

. "$(cd "$(dirname "$0")" && pwd)/_common.sh"

[ $# -ge 1 ] || die "쓰는 법: ./vm-ssh.sh <VM이름> [VM 안에서 돌릴 명령]"
NAME="$1"; shift

[ -f "$KEY_RUN" ] || prepare_key
vm_ssh "$NAME" "$@"
