#!/bin/sh
# r1의 "들어오는 쪽"에서 하는 일 두 가지
#   분류(classify): 어느 포트로 들어온 누구의 패킷인지 고름
#   표시(mark)    : 고른 패킷의 IP 머리에 DSCP 값을 적음
#
# 왜 들어오는 쪽에서 하나
#   - 실제 데이터센터도 바깥에서 들어오는 표시는 믿지 않고 경계 스위치에서 다시 적음
#   - 여기서 적어 두면 뒤쪽 장비는 "주소"가 아니라 "표시"만 보고 줄을 세울 수 있음
#
# DSCP 값과 TOS 바이트
#   DSCP는 IP 머리 TOS 바이트의 윗 6비트임. 그래서 tc에는 "DSCP * 4" 값을 적음
#   EF(46) -> 46*4 = 184 = 0xb8 , 기본(0) -> 0x00
#   retain 0xfc 는 아래 2비트(ECN 자리)는 건드리지 않고 DSCP 6비트만 바꾸라는 뜻
#
# action csum ip 를 꼭 붙여야 함
#   IP 머리를 고치면 머리 검사값(체크섬)이 맞지 않게 됨. 그대로 두면 라우터가 그 패킷을 버림
#   (2026-11-23 실측: csum 없이 하니 h1 -> h3 ping이 100% 안 됨)
#   TOS 바이트는 TCP, UDP 검사값에는 들어가지 않으므로 ip 만 다시 계산하면 됨
#
# pedit 뒤에 pipe 를 꼭 붙여야 함
#   tc의 action은 줄줄이 이어 붙일 수 있는데, 기본 끝맺음이 pass(여기서 끝)임
#   pedit 끝에 pipe 를 적어야 "다음 action(csum)으로 넘겨라"가 됨
#   (2026-11-23 실측: pipe 없이 하니 csum이 한 번도 실행되지 않아 ping이 계속 안 됨)
set -e

# 이미 걸려 있으면 지우고 다시 검 (2>/dev/null: 없을 때 나는 오류 숨김)
tc qdisc del dev eth1 clsact 2>/dev/null || true
tc qdisc del dev eth2 clsact 2>/dev/null || true

# eth1 = h1(중요 트래픽)이 붙은 포트 -> EF(46)로 표시
tc qdisc add dev eth1 clsact
tc filter add dev eth1 ingress protocol ip prio 1 u32 \
   match ip src 10.60.1.10/32 \
   action pedit ex munge ip dsfield set 0xb8 retain 0xfc pipe \
   action csum ip pass

# eth2 = h2(대량 트래픽)이 붙은 포트 -> 기본(0)으로 표시
# h2가 스스로 EF라고 적어 보내도 여기서 0으로 덮어씀("보내는 쪽 말을 믿지 않음")
tc qdisc add dev eth2 clsact
tc filter add dev eth2 ingress protocol ip prio 1 u32 \
   match ip src 10.60.2.10/32 \
   action pedit ex munge ip dsfield set 0x00 retain 0xfc pipe \
   action csum ip pass

echo "mark.sh: eth1 -> DSCP EF(46), eth2 -> DSCP 0 표시 규칙을 걸었습니다"
