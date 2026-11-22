#!/usr/bin/env bash
# VM 안에서 root 권한으로 도는 Soft-RoCE 설정 스크립트.
# vm-up.sh 가 ssh 로 들여보내 실행함. 손으로 돌릴 때는 VM 안에서 `sudo bash setup-rxe.sh`
#
# Soft-RoCE(rdma_rxe): RDMA 전용 랜카드 없이, 평범한 랜카드 위에서 RDMA 를 흉내 내는 커널 기능.
# 실제 InfiniBand 나 RoCE 전용 랜카드가 아니므로 성능은 실제 장비와 다름

set -euo pipefail

RXE_DEV="${RXE_DEV:-rxe0}"
RDMA_NET_PREFIX="${RDMA_NET_PREFIX:-10.50.0.}"

echo "== 1. 내부망 랜카드 찾기 =="
NETDEV="$(ip -o -4 addr show | awk -v p="$RDMA_NET_PREFIX" '$4 ~ "^"p {print $2; exit}')"
if [ -z "$NETDEV" ]; then
  echo "실패: ${RDMA_NET_PREFIX}x 주소를 가진 랜카드가 없음" >&2
  ip -o -4 addr show >&2
  exit 1
fi
echo "내부망 랜카드: $NETDEV ($(ip -o -4 addr show dev "$NETDEV" | awk '{print $4}'))"

echo "== 2. rdma_rxe 커널 모듈 올리기 =="
if ! modprobe rdma_rxe; then
  echo "실패: rdma_rxe 모듈을 올리지 못함. linux-modules-extra-$(uname -r) 가 깔렸는지 확인" >&2
  exit 1
fi
lsmod | grep -E "^rdma_rxe|^ib_uverbs" || true

echo "== 3. RDMA 장치 만들기 ($RXE_DEV on $NETDEV) =="
if rdma link show 2>/dev/null | grep -q "^link ${RXE_DEV}/"; then
  echo "$RXE_DEV 이 이미 있음"
else
  rdma link add "$RXE_DEV" type rxe netdev "$NETDEV"
fi
rdma link show

echo "== 4. 다시 켜도 살아 있게 systemd 에 등록 =="
cat > /etc/systemd/system/lab5-rxe.service <<EOF
[Unit]
Description=aidc lab5 Soft-RoCE link ($RXE_DEV on $NETDEV)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/modprobe rdma_rxe
ExecStart=/bin/sh -c 'rdma link show | grep -q "^link ${RXE_DEV}/" || rdma link add ${RXE_DEV} type rxe netdev ${NETDEV}'
ExecStop=/bin/sh -c 'rdma link delete ${RXE_DEV} || true'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab5-rxe.service >/dev/null 2>&1 || systemctl enable lab5-rxe.service

echo "== 5. 장치 확인 =="
ibv_devices
echo "--- ibv_devinfo ---"
ibv_devinfo -d "$RXE_DEV" | sed -n '1,20p'

echo "== 6. GID 표 (RoCEv2 자리를 찾기 위함) =="
GIDDIR="/sys/class/infiniband/${RXE_DEV}/ports/1"
printf '%-6s %-40s %s\n' "번호" "GID" "종류"
# GID 자리는 1024개라 하나씩 cat 하면 VM 한 대에 약 60초 걸림.
# 빈 자리(모두 0)가 아닌 파일만 grep 으로 먼저 골라 몇 개만 읽음
for f in $(grep -L '^0000:0000:0000:0000:0000:0000:0000:0000$' "$GIDDIR"/gids/* 2>/dev/null); do
  idx="$(basename "$f")"
  gid="$(cat "$f")"
  typ="$(cat "$GIDDIR/gid_attrs/types/$idx" 2>/dev/null || echo '-')"
  printf '%-6s %-40s %s\n' "$idx" "$gid" "$typ"
done

echo
echo "설정 끝. RoCEv2(UDP 4791)로 시험하려면 위 표에서 종류가 RoCE v2 인 번호를 -g 또는 -x 에 씀"
