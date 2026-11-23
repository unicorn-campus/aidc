#!/usr/bin/env bash
# lab6를 처음 상태로 되돌림 (깨진 곳을 고치지 않고 지우고 다시 띄움)
#
# 사용
#   ./reset.sh         QoS를 켠 상태로 되돌리고 바로 검사함 (check.sh 가 보는 상태)
#   ./reset.sh start   실습 시작 상태(QoS 없음)로 되돌림. 1단계부터 다시 해 볼 때 씀
#
# 왜 기본값이 "QoS 켠 상태"인가
#   check.sh 는 "QoS가 제대로 동작하는가"를 보는 검사임. 그래서 되돌린 자리도 그 상태여야
#   "되돌렸더니 다시 통과"를 확인할 수 있음. 실습을 처음부터 다시 밟고 싶으면 start 를 씀
cd "$(dirname "$0")"
MODE="${1:-on}"
case "$MODE" in on|start) ;; *) echo "사용법: ./reset.sh [start]" >&2; exit 1;; esac

./clab.sh deploy -t lab6.clab.yml --reconfigure >/dev/null 2>&1 \
  || { echo "다시 띄우기 실패. docker 가 떠 있는지 확인하세요"; exit 1; }
echo "다시 띄웠습니다. OSPF 이웃이 맺어질 때까지 15초 기다립니다..."
sleep 15

if [ "$MODE" = start ]; then
  docker exec clab-lab6-r1 sh /root/shape.sh off
  echo "실습 시작 상태입니다(좁은 구간만 있고 QoS 없음). 1단계부터 다시 하세요"
  echo "QoS를 켜는 차례가 되면: docker exec clab-lab6-r1 sh /root/shape.sh on"
  exit 0
fi

docker exec clab-lab6-r1 sh /root/shape.sh on
echo
./check.sh
