#!/usr/bin/env bash
# containerlab을 설치하지 않고 컨테이너로 실행함 (Docker Desktop 환경용)
# 사용 예: ./clab.sh deploy -t lab1.clab.yml
exec docker run --rm --privileged \
  --network host \
  --pid host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/run/netns:/var/run/netns \
  -v /var/lib/docker/containers:/var/lib/docker/containers \
  -v "$(pwd)":"$(pwd)" \
  -w "$(pwd)" \
  ghcr.io/srl-labs/clab:latest containerlab "$@"
