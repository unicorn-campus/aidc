#!/usr/bin/env bash
# lab1을 처음 상태로 되돌림 (지우고 다시 띄움)
cd "$(dirname "$0")"
./clab.sh deploy -t lab1.clab.yml --reconfigure >/dev/null 2>&1 || { echo "다시 띄우기 실패"; exit 1; }
echo "다시 띄웠습니다. OSPF가 붙을 때까지 15초 기다립니다..."
sleep 15
./check.sh
