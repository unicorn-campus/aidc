# lab3 VxLAN 터널을 손으로 만들기

## 이 실습에서 배우는 것
- lab2와 같은 leaf-spine 위에서, 서로 다른 leaf에 꽂힌 서버 h1과 h2를 같은 망(10.10.10.0/24)에 있는 것처럼 묶음  
- 묶는 기술이 VxLAN임. leaf가 서버의 패킷을 다른 포장지(UDP)로 한 번 더 싸서 spine 너머의 상대 leaf로 보냄  
- 상대 leaf의 주소(VTEP)를 사람이 손으로 적어 줌. 다음 실습(lab4)에서는 이 손작업을 EVPN이 대신 함
- lab2와 달라진 점: BGP는 leaf의 대표 주소(루프백)끼리 닿게 하는 일만 하고, 서버 대역은 BGP로 알리지 않음

## 구성도와 주소표
```text
            +------------------+            +------------------+
            | spine1  AS 65000 |            | spine2  AS 65000 |
            | lo 10.0.0.1      |            | lo 10.0.0.2      |
            +--eth1------eth2--+            +--eth1------eth2--+
                |          \                    /          |
                |           +------\  /--------+           |
                |                   \/                     |
                |           +------/  \--------+           |
                |          /                    \          |
            +--eth1------eth2--+            +--eth1------eth2--+
            | leaf1   AS 65101 |            | leaf2   AS 65102 |
            | VTEP 10.0.0.11   |            | VTEP 10.0.0.12   |
            | br100 = eth3     |            | br100 = eth3     |
            |       + vxlan100 |            |       + vxlan100 |
            +-------eth3-------+            +-------eth3-------+
                     |                               |
              h1 10.10.10.11/24               h2 10.10.10.12/24

  터널(VNI 100):
  h1 -- [leaf1 br100] vxlan100 ==(UDP 4789, 10.0.0.11 <-> 10.0.0.12)== vxlan100 [leaf2 br100] -- h2
```

| 장비 | 인터페이스 | 주소 | 비고 |
|------|-----------|------|------|
| spine1 | lo | 10.0.0.1/32 | AS 65000 |
| spine2 | lo | 10.0.0.2/32 | AS 65000 |
| leaf1 | lo | 10.0.0.11/32 | AS 65101, 이 주소가 VTEP 주소(터널 출발지) |
| leaf1 | eth3, vxlan100 | IP 없음 | 둘 다 브리지 br100에 꽂힘 |
| leaf2 | lo | 10.0.0.12/32 | AS 65102, 이 주소가 VTEP 주소 |
| leaf2 | eth3, vxlan100 | IP 없음 | 둘 다 브리지 br100에 꽂힘 |
| h1 | eth1 | 10.10.10.11/24 | leaf1 eth3에 연결 |
| h2 | eth1 | 10.10.10.12/24 | leaf2 eth3에 연결 |

- 스위치 사이 선(eth1, eth2)에는 IP 주소가 없음(BGP unnumbered)  
- 컨테이너 이름은 `clab-lab3-spine1`, `clab-lab3-spine2`, `clab-lab3-leaf1`, `clab-lab3-leaf2`, `clab-lab3-h1`, `clab-lab3-h2`임

## 준비물
- Docker Desktop이 켜져 있어야 함  
- Windows 터미널(또는 PowerShell)을 열고 `wsl`을 입력해 WSL을 엶  
- `check.sh`가 WSL에서 `jq`를 쓰므로 깔려 있어야 함(`jq --version`으로 확인, 없으면 `sudo apt install -y jq`)  
- 실습 폴더로 이동함. 아래 `<사용자>`는 내 Windows 사용자 이름으로 바꿈  
  ```bash
  cd /mnt/c/Users/<사용자>/class/aidc/labs/lab3-vxlan-static
  ```
- 앞 실습(lab2 등)이 떠 있으면 그 폴더에서 먼저 끔

## 따라 하기
1. 실습 환경을 띄움  
   ```bash
   ./reset.sh
   ```
   이렇게 나오면 성공: `다시 띄웠습니다...` 뒤 20초 정도 기다리면 검사 5개 항목이 나오고 마지막 줄이 `결과: 모두 통과`임  
   뜻: 처음 상태로 지우고 다시 띄운 뒤 검사(`check.sh`)까지 한 번에 돌려 줌

2. 터널 바깥 길(언더레이)을 확인함  
   ```bash
   docker exec clab-lab3-leaf1 vtysh -c "show ip route 10.0.0.12"
   ```
   이렇게 나오면 성공: `Known via "bgp"`가 보이고 다음 길이 `via eth1`, `via eth2` 두 줄임(`fe80::` 주소는 바뀔 수 있음)  
   ```text
   Routing entry for 10.0.0.12/32
     Known via "bgp", distance 20, metric 0, best
     * fe80::a8c1:abff:fe2f:7fb6, via eth2, weight 1
     * fe80::a8c1:abff:fead:8edd, via eth1, weight 1
   ```
   뜻: leaf1이 leaf2의 VTEP 주소(10.0.0.12)로 가는 길을 BGP로 배웠고 spine 2대를 모두 씀

3. 손으로 적은 상대 VTEP을 확인함  
   ```bash
   docker exec clab-lab3-leaf1 bridge fdb show dev vxlan100
   ```
   이렇게 나오면 성공: `00:00:00:00:00:00 dst 10.0.0.12 self permanent` 줄이 보임(MAC 주소가 적힌 다른 줄은 바뀔 수 있음)  
   ```text
   aa:c1:ab:aa:10:78 dst 10.0.0.12 self 
   46:12:0e:e4:fa:d0 dst 10.0.0.12 self 
   00:00:00:00:00:00 dst 10.0.0.12 self permanent
   ```
   (위 출력은 앞부분의 `master br100` 줄을 줄여 옮긴 것임. 실제로는 줄이 더 나옴)  
   뜻: `00:00:00:00:00:00 ... permanent` 줄이 `cfg/vxlan-static.sh`가 손으로 넣은 줄임.  
   "행선지를 모르는 패킷은 10.0.0.12로 보내라"는 뜻임. MAC이 적힌 줄은 터널로 들어온 패킷을 보고 커널이 스스로 배운 줄임

4. VxLAN 인터페이스의 값을 확인함  
   ```bash
   docker exec clab-lab3-leaf1 ip -d link show vxlan100
   ```
   이렇게 나오면 성공: 출력 가운데 `vxlan id 100 local 10.0.0.11 srcport 0 0 dstport 4789`가 보임  
   뜻: 터널 번호(VNI)는 100, 출발지 주소는 내 VTEP(10.0.0.11), 포트는 표준 4789임

5. 서버끼리 통신해 봄  
   ```bash
   docker exec clab-lab3-h1 ping -c 3 10.10.10.12
   ```
   이렇게 나오면 성공: `3 packets transmitted, 3 received, 0% packet loss`  
   뜻: 서로 다른 leaf에 꽂혀 있는 h1과 h2가 같은 망처럼 통신함

6. 터널 안을 들여다봄(선택). 먼저 이 명령으로 leaf1의 UDP 4789 패킷을 잡기 시작함  
   ```bash
   docker run --rm --network container:clab-lab3-leaf1 ghcr.io/hellt/network-multitool:latest \
     timeout 8 tcpdump -nni any -c 4 udp port 4789
   ```
   8초 안에 다른 터미널 창에서 5번의 ping을 다시 실행함  
   이렇게 나오면 성공: 바깥 머리는 VTEP 주소끼리, 안쪽은 서버 주소끼리인 줄이 짝으로 보임(포트 번호와 id는 바뀔 수 있음)  
   ```text
   IP 10.0.0.11.36837 > 10.0.0.12.4789: VXLAN, flags [I] (0x08), vni 100
   IP 10.10.10.11 > 10.10.10.12: ICMP echo request, id 62966, seq 1, length 64
   ```
   뜻: 서버의 ping 패킷(10.10.10.x)이 VTEP 주소(10.0.0.x)가 적힌 UDP 포장지에 싸여 spine을 지나감  
   시작할 때 나오는 `Cannot set device feature settings` 같은 줄은 무시해도 됨

7. EVPN을 쓰지 않는지 확인함  
   ```bash
   docker exec clab-lab3-leaf1 vtysh -c "show evpn vni"
   ```
   이렇게 나오면 성공: 아무 내용도 출력되지 않고 끝남  
   뜻: 이 실습은 EVPN이 꺼져 있어서 VNI 정보가 비어 있음. lab4에서 여기에 내용이 채워짐

8. 검사를 돌림  
   ```bash
   ./check.sh
   ```
   이렇게 나오면 성공: 항목 5개가 모두 `[통과]`이고 마지막 줄이 `결과: 모두 통과`임  
   ```text
   1) leaf마다 spine 2대와 BGP 이웃이 맺어졌는가 (언더레이)
     [통과] leaf1: 이웃 2개 정상
   3) vxlan100이 VNI 100, 내 루프백, UDP 4789로 만들어졌는가
     [통과] leaf1: vxlan100 = VNI 100, local 10.0.0.11, 포트 4789
   4) 상대 VTEP을 fdb에 손으로 적었고, EVPN은 쓰지 않는가
     [통과] leaf1: fdb에 상대 VTEP 10.0.0.12 를 손으로 적었고 EVPN은 꺼져 있음
   5) 서버 h1에서 h2로 통신되는가
     [통과] h1 -> h2 통신 정상
   결과: 모두 통과
   ```
   (위는 leaf2와 2번 항목 줄을 줄여 옮긴 것임. 실제로는 항목마다 leaf1, leaf2 두 줄씩 나옴)  
   뜻: ping이 된다는 것만이 아니라 "VNI 100 터널이 의도대로 만들어졌고 BGP와 손으로 적은 fdb로 동작하는가"까지 확인함

9. 실습 환경을 끔  
   ```bash
   ./clab.sh destroy -t lab3.clab.yml --cleanup
   ```
   이렇게 나오면 성공: `Removed container name=clab-lab3-...` 줄이 6개 나오고 `clab-lab3` 임시 폴더가 지워짐  
   뜻: 컨테이너 6개를 모두 지움

## 고장 연습
`./fault-demo.sh`는 고장을 하나씩 내고 `check.sh`를 돌린 뒤 바로 원래대로 되돌림. 마지막에 `복구 확인`으로 다시 검사함  
(아래 표는 2026-11-23 강사 PC에서 `fault-demo.sh`를 실제로 돌린 결과임)

| 번호 | 일부러 내는 고장 | 실패로 잡힌 검사 | ping |
|------|------------------|------------------|------|
| 1 | leaf1이 fdb에 상대 VTEP을 틀리게 적음(10.0.0.12 대신 10.0.0.21) | 4번(주소가 다름) | 됨 |
| 2 | leaf1이 fdb에서 상대 VTEP 줄을 빼먹음 | 4번(손으로 적은 줄이 없음) | 됨 |
| 3 | leaf2의 vxlan100 local 주소가 틀림(10.0.0.22) | 3번(local 주소가 다름), 5번(통신 안 됨) | 안 됨 |
| 4 | leaf2가 자기 루프백(VTEP 주소)을 BGP로 알리지 않음 | 2번(상대 VTEP으로 가는 길이 없음), 5번 | 안 됨 |
| 5 | BGP 대신 손으로 static 경로를 넣어 VTEP에 닿게 함(편법) | 2번(BGP가 아니라 static이라고 알려 줌) | 됨 |

- 1번과 2번은 fdb가 틀렸는데도 ping이 됨. 커널이 앞서 터널로 들어온 패킷을 보고 배운 MAC 줄이 아직 남아 있기 때문임.  
  시간이 지나 그 줄이 지워지면 통신이 끊기므로, ping이 아니라 검사로 잡아야 하는 고장임

## 막혔을 때
1. Docker Desktop이 켜져 있는지, `docker ps`에 `clab-lab3-`로 시작하는 컨테이너 6개가 있는지 확인함  
2. `./check.sh`에서 1, 2번이 실패하면 띄운 지 20초가 안 지났을 수 있으므로 잠시 기다린 뒤 다시 돌림  
3. 4번이 실패하면 상대 VTEP 주소를 틀리게 적었을 수 있음. `bridge fdb show dev vxlan100`으로 `permanent` 줄의 주소가 상대 leaf의 VTEP인지 확인함  
4. 실패 항목 아래에 나오는 `힌트:` 줄을 읽고 그대로 따라 해 봄  
5. 두 번 시도해도 안 되면 `./reset.sh`로 처음 상태로 되돌림

## 용어 풀이
| 용어 | 쉬운 말 |
|------|---------|
| 언더레이(underlay) | 터널이 지나가는 바탕 길. 여기서는 leaf-spine과 BGP로 만든 길 |
| 오버레이(overlay) | 바탕 길 위에 가상으로 만든 망. 여기서는 h1과 h2가 속한 10.10.10.0/24 |
| VxLAN | 서버의 패킷을 UDP로 한 번 더 싸서, 멀리 떨어진 스위치 사이에서도 같은 망처럼 쓰게 하는 기술 |
| VTEP | 터널의 출입구가 되는 장비(또는 그 주소). 이 실습에서는 leaf의 루프백 주소(10.0.0.11, 10.0.0.12) |
| VNI | 터널 하나를 구분하는 번호(여기서는 100). 두 leaf가 같은 번호를 써야 같은 망으로 묶임 |
| 캡슐화 | 원래 패킷을 다른 패킷 안에 넣어 포장하는 것 |
| 브리지(br100) | 같은 망의 포트들을 한 스위치처럼 묶어 주는 리눅스의 가상 스위치 |
| MAC 주소 | 네트워크 카드마다 붙은 고유 번호. 같은 망 안에서는 이 번호로 상대를 찾음 |
| fdb | "이 MAC 주소는 어느 쪽으로 보내라"를 적어 둔 표. 여기서는 vxlan100의 fdb에 상대 VTEP 주소를 적음 |
| permanent | 사라지지 않게 고정해 둔 항목. 손으로 넣은 줄에 붙음 |
| 루프백(lo) | 장비 안의 가상 구멍. 선이 끊겨도 꺼지지 않아 장비의 대표 주소로 씀 |
| BGP unnumbered | 선에 IP를 붙이지 않고 인터페이스 이름만으로 BGP 이웃을 맺는 방식 |
| MTU | 한 번에 보낼 수 있는 패킷의 최대 크기. 이 실습은 서버와 eth3을 1500으로 맞춰 둠 |
| tcpdump | 지나가는 패킷을 잡아서 보여 주는 명령 |
