#!/bin/sh
# r1의 eth3(좁은 구간)에서 "나가는 쪽" 큐를 만듦
#
# 사용법
#   sh /root/shape.sh off    좁은 구간만 만들고 줄은 하나 (QoS 없음)
#   sh /root/shape.sh on     같은 좁은 구간에 DSCP별로 줄을 나눔 (QoS 있음)
#   sh /root/shape.sh clear  큐를 모두 지움 (좁은 구간도 없어짐)
#
# off와 on의 차이는 "줄이 하나냐 여럿이냐"뿐임. 속도(10Mbit/s)는 둘 다 같음.
# 그래야 "QoS 때문에 달라졌다"고 말할 수 있음
set -e
DEV=eth3
RATE=10mbit          # 좁은 구간의 전체 속도
MODE="${1:-on}"

tc qdisc del dev $DEV root 2>/dev/null || true

case "$MODE" in
  clear)
    echo "shape.sh: $DEV 의 큐를 모두 지웠습니다(좁은 구간 없음)"
    exit 0
    ;;

  off)
    # 줄 하나짜리. 먼저 온 패킷이 먼저 나감(FIFO)
    # 대량 트래픽이 줄을 가득 채우면 중요한 트래픽도 그 뒤에 서야 함
    tc qdisc add dev $DEV root handle 1: htb default 20
    tc class add dev $DEV parent 1:  classid 1:1  htb rate $RATE ceil $RATE
    tc class add dev $DEV parent 1:1 classid 1:20 htb rate $RATE ceil $RATE quantum 1514
    tc qdisc add dev $DEV parent 1:20 handle 120: pfifo limit 1000
    echo "shape.sh: $DEV = $RATE 좁은 구간, 줄 1개(FIFO). QoS 없음"
    ;;

  on)
    # 줄 세 개. 전체 10Mbit/s를 나눠 씀
    #   1:30 제어(DSCP CS6=48, 0xc0) : 1Mbit 보장, 가장 먼저 내보냄
    #                                   라우팅 대화(OSPF)가 끊기지 않게 하는 줄
    #   1:10 중요(DSCP EF =46, 0xb8) : 5Mbit 보장, 남으면 10Mbit까지 씀
    #   1:20 나머지(기본값)          : 4Mbit 보장, 남으면 10Mbit까지 씀
    # rate = 보장, ceil = 최대. 남는 대역은 서로 빌려 씀(버리지 않음)
    tc qdisc add dev $DEV root handle 1: htb default 20
    tc class add dev $DEV parent 1:  classid 1:1  htb rate $RATE ceil $RATE
    tc class add dev $DEV parent 1:1 classid 1:30 htb rate 1mbit ceil $RATE prio 0 quantum 1514
    tc class add dev $DEV parent 1:1 classid 1:10 htb rate 5mbit ceil $RATE prio 1 quantum 1514
    tc class add dev $DEV parent 1:1 classid 1:20 htb rate 4mbit ceil $RATE prio 2 quantum 1514

    # 줄마다 "줄 안에서 어떻게 기다리게 할지"를 따로 정함
    tc qdisc add dev $DEV parent 1:30 handle 130: pfifo limit 64
    # fq_codel: 줄이 길어지면 스스로 줄여 지연을 낮게 유지함
    tc qdisc add dev $DEV parent 1:10 handle 110: fq_codel
    # red + ecn: 줄이 길어지면 버리는 대신 "혼잡하다"고 패킷에 표시함(ECN)
    tc qdisc add dev $DEV parent 1:20 handle 120: red \
       limit 400000 min 30000 max 90000 avpkt 1000 burst 55 \
       bandwidth $RATE probability 0.02 ecn

    # 어느 줄에 설지는 주소가 아니라 DSCP 표시로 고름
    # dsfield 0xfc = DSCP 6비트만 보고 ECN 2비트는 보지 않겠다는 뜻
    tc filter add dev $DEV parent 1: protocol ip prio 1 u32 \
       match ip dsfield 0xc0 0xfc flowid 1:30
    tc filter add dev $DEV parent 1: protocol ip prio 2 u32 \
       match ip dsfield 0xb8 0xfc flowid 1:10
    echo "shape.sh: $DEV = $RATE 좁은 구간, 줄 3개(제어 1Mbit / 중요 5Mbit / 나머지 4Mbit). QoS 있음"
    ;;

  *)
    echo "사용법: sh shape.sh [on|off|clear]" >&2
    exit 1
    ;;
esac
