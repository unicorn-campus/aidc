#!/usr/bin/env bash
# lab4를 처음 상태로 되돌림 (지우고 다시 띄움)
cd "$(dirname "$0")"
./clab.sh deploy -t lab4.clab.yml --reconfigure >/dev/null 2>&1 || { echo "다시 띄우기 실패"; exit 1; }
echo "다시 띄웠습니다. BGP와 EVPN이 붙을 때까지 25초 기다립니다..."
sleep 25
./check.sh
