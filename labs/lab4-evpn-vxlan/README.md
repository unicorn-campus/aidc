# lab4 EVPN으로 VxLAN 자동화하기

## 이 실습에서 배우는 것
- lab3과 같은 구성(leaf-spine, VNI 100, h1과 h2가 같은 망)에서, 손으로 적던 상대 VTEP 주소를 지움  
- leaf와 spine이 BGP로 EVPN 경로를 주고받고, leaf가 그 경로를 보고 터널 행선지를 스스로 채움  
- lab3과 달라진 점: 상대 VTEP은 타입 3 경로로, 상대 서버의 MAC 주소는 타입 2 경로로 배움

## lab3과 달라진 점
| 구분 | lab3 (손으로) | lab4 (EVPN) |
|------|---------------|-------------|
| 상대 VTEP | `bridge fdb append ...`로 손으로 적음 | 적지 않음. 타입 3 경로로 배움 |
| 상대 서버 MAC | 터널로 들어온 패킷을 보고 커널이 배움 | 타입 2 경로로 배움 |
| leaf BGP | `ipv4 unicast`만 | `ipv4 unicast`와 `l2vpn evpn` 둘 다 |
| spine BGP | `ipv4 unicast`만 | `l2vpn evpn`도 켬(경로를 전달만 함) |

## 구성도와 주소표
```text
            +------------------+            +------------------+
            | spine1  AS 65000 |            | spine2  AS 65000 |
            | lo 10.0.0.1      |            | lo 10.0.0.2      |
            | EVPN 경로 전달만 |            | EVPN 경로 전달만 |
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
```

| 장비 | 인터페이스 | 주소 | 비고 |
|------|-----------|------|------|
| spine1 | lo | 10.0.0.1/32 | AS 65000 |
| spine2 | lo | 10.0.0.2/32 | AS 65000 |
| leaf1 | lo | 10.0.0.11/32 | AS 65101, VTEP 주소 |
| leaf1 | eth3, vxlan100 | IP 없음 | 둘 다 브리지 br100에 꽂힘 |
| leaf2 | lo | 10.0.0.12/32 | AS 65102, VTEP 주소 |
| leaf2 | eth3, vxlan100 | IP 없음 | 둘 다 브리지 br100에 꽂힘 |
| h1 | eth1 | 10.10.10.11/24 | leaf1 eth3에 연결 |
| h2 | eth1 | 10.10.10.12/24 | leaf2 eth3에 연결 |

- BGP 이웃 하나 위에서 두 가지 정보를 주고받음. `ipv4 unicast`는 VTEP 주소끼리 닿는 길,  
  `l2vpn evpn`은 "나는 VNI 100의 VTEP임"(타입 3)과 "이 MAC은 내 뒤에 있음"(타입 2)임  
- 컨테이너 이름은 `clab-lab4-spine1`, `clab-lab4-spine2`, `clab-lab4-leaf1`, `clab-lab4-leaf2`, `clab-lab4-h1`, `clab-lab4-h2`임

## 준비물
- Docker Desktop이 켜져 있어야 함  
- Windows 터미널(또는 PowerShell)을 열고 `wsl`을 입력해 WSL을 엶  
- `check.sh`가 WSL에서 `jq`를 쓰므로 깔려 있어야 함(`jq --version`으로 확인, 없으면 `sudo apt install -y jq`)  
- 실습 폴더로 이동함. 아래 `<사용자>`는 내 Windows 사용자 이름으로 바꿈  
  ```bash
  cd /mnt/c/Users/<사용자>/class/aidc/labs/lab4-evpn-vxlan
  ```
- 앞 실습(lab3 등)이 떠 있으면 그 폴더에서 먼저 끔

## 따라 하기
1. 실습 환경을 띄움  
   ```bash
   ./reset.sh
   ```
   이렇게 나오면 성공: `다시 띄웠습니다...` 뒤 25초 정도 기다리면 검사 5개 항목이 나오고 마지막 줄이 `결과: 모두 통과`임  
   뜻: 처음 상태로 지우고 다시 띄운 뒤 검사(`check.sh`)까지 한 번에 돌려 줌.  
   검사가 먼저 서버끼리 ping을 해 주므로, 이 뒤의 확인에서 서버 MAC이 이미 배워진 상태임

2. 서버끼리 통신해 봄  
   ```bash
   docker exec clab-lab4-h1 ping -c 3 10.10.10.12
   ```
   이렇게 나오면 성공: `3 packets transmitted, 3 received, 0% packet loss`  
   뜻: lab3과 똑같이 h1과 h2가 같은 망처럼 통신함. 겉으로는 달라진 것이 없고, 안쪽 동작이 달라짐

3. EVPN 이웃을 확인함  
   ```bash
   docker exec clab-lab4-leaf1 vtysh -c "show bgp l2vpn evpn summary"
   ```
   이렇게 나오면 성공: `spine1(eth1)`, `spine2(eth2)` 두 줄이 보이고 `State/PfxRcd` 칸에 숫자 2가 보임(시간 값은 바뀔 수 있음)  
   ```text
   Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt
   spine1(eth1)    4      65000        21        23        4    0    0 00:00:32            2        4
   spine2(eth2)    4      65000        21        23        4    0    0 00:00:32            2        4
   ```
   뜻: leaf1이 spine 2대와 EVPN 경로를 주고받는 중임(`PfxRcd 2`는 경로 2개를 받았다는 뜻)

4. EVPN 경로 목록을 봄  
   ```bash
   docker exec clab-lab4-leaf1 vtysh -c "show bgp l2vpn evpn route"
   ```
   이렇게 나오면 성공: 맨 아래에 `Displayed 4 prefixes (6 paths)`가 보임.  
   `10.0.0.11`과 `10.0.0.12` 아래에 `[2]:...`(타입 2) 줄과 `[3]:...`(타입 3) 줄이 하나씩 있음  
   ```text
   Route Distinguisher: 10.0.0.11:2
    *>  [2]:[0]:[48]:[aa:c1:ab:5d:80:45]
    *>  [3]:[0]:[32]:[10.0.0.11]
   Route Distinguisher: 10.0.0.12:2
    *>  [2]:[0]:[48]:[aa:c1:ab:aa:64:6b]
    *>  [3]:[0]:[32]:[10.0.0.12]
   Displayed 4 prefixes (6 paths)
   ```
   (위는 핵심 줄만 옮긴 것이며, MAC 주소는 띄울 때마다 바뀜. 실제로는 다음 홉과 RT 줄도 함께 나옴)  
   뜻: `[3]:...[10.0.0.12]`는 "leaf2가 VNI 100의 VTEP임"(타입 3), `[2]:...[MAC]`은 "이 MAC이 그 leaf 뒤에 있음"(타입 2)임.  
   상대 경로가 `10.0.0.12(spine1)`, `10.0.0.12(spine2)`로 두 번 보이는 것은 같은 경로를 spine 2대에게서 받았다는 뜻임.  
   종류별로 보려면 끝에 `type macip`(타입 2) 또는 `type multicast`(타입 3)를 붙임

5. 상대 VTEP을 EVPN으로 배웠는지 확인함  
   ```bash
   docker exec clab-lab4-leaf1 vtysh -c "show evpn vni 100"
   ```
   이렇게 나오면 성공: `Remote VTEPs for this VNI:` 아래에 `10.0.0.12 flood: HER`가 보임  
   ```text
   VNI: 100
    Local VTEP IP: 10.0.0.11
    Remote VTEPs for this VNI:
     10.0.0.12 flood: HER
    Number of MACs (local and remote) known for this VNI: 2
   ```
   (위는 핵심 줄만 옮긴 것임)  
   뜻: leaf1이 손으로 적지 않았는데도 leaf2의 터널 주소를 BGP로 알아냄. `HER`는 여러 곳에 알릴 때 상대마다 복사해서 보내는 방식임

6. 상대 서버의 MAC을 배웠는지 확인함  
   ```bash
   docker exec clab-lab4-leaf1 vtysh -c "show evpn mac vni 100"
   ```
   이렇게 나오면 성공: `remote`로 `10.0.0.12`가 적힌 줄 하나와 `local`로 `eth3`이 적힌 줄 하나가 보임(MAC 주소는 바뀔 수 있음)  
   ```text
   MAC               Type   Flags Intf/Remote ES/VTEP            VLAN  Seq #'s
   aa:c1:ab:aa:64:6b remote       10.0.0.12                            0/0
   aa:c1:ab:5d:80:45 local        eth3                                 0/0
   ```
   뜻: h1의 MAC은 내 쪽 eth3에서 직접 배웠고(`local`), h2의 MAC은 leaf2가 알려 줘서 알았음(`remote`)

7. 리눅스 커널의 fdb를 봄  
   ```bash
   docker exec clab-lab4-leaf1 bridge fdb show dev vxlan100
   ```
   이렇게 나오면 성공: `extern_learn`이 붙은 줄과 `00:00:00:00:00:00 dst 10.0.0.12 self permanent` 줄이 보임  
   ```text
   aa:c1:ab:aa:64:6b dst 10.0.0.12 self extern_learn 
   00:00:00:00:00:00 dst 10.0.0.12 self permanent
   ```
   (위는 `dst`가 있는 줄만 옮긴 것이며, 실제로는 `master br100` 줄도 함께 나옴)  
   뜻: `extern_learn`은 커널이 아니라 FRR이 넣은 줄이라는 표시임. `00:00:00:00:00:00` 줄은 lab3과 모양이 같지만 손으로 넣은 것이 아니라,  
   타입 3 경로를 받아 FRR이 넣은 줄임

8. 터널 안을 들여다봄(선택, lab3 6번과 같은 방법)  
   ```bash
   docker run --rm --network container:clab-lab4-leaf1 ghcr.io/hellt/network-multitool:latest \
     timeout 8 tcpdump -nni any -c 4 udp port 4789
   ```
   8초 안에 다른 터미널 창에서 2번의 ping을 다시 실행함  
   이렇게 나오면 성공: VTEP 주소끼리 UDP 4789, `vni 100` 줄과 서버 주소끼리 ICMP 줄이 짝으로 보임(포트 번호와 id는 바뀔 수 있음)  
   ```text
   IP 10.0.0.12.36837 > 10.0.0.11.4789: VXLAN, flags [I] (0x08), vni 100
   IP 10.10.10.12 > 10.10.10.11: ICMP echo reply, id 33833, seq 1, length 64
   ```
   뜻: 데이터가 지나가는 모습은 lab3과 같음. 달라진 것은 행선지를 누가 채웠느냐임

9. 검사를 돌림  
   ```bash
   ./check.sh
   ```
   이렇게 나오면 성공: 항목 5개가 모두 `[통과]`이고 마지막 줄이 `결과: 모두 통과`임  
   ```text
   2) 상대 VTEP을 손으로 적지 않고 EVPN으로 배웠는가
     [통과] leaf1: 원격 VTEP 10.0.0.12 를 EVPN으로 배움 (타입 3 경로 있음)
   3) 상대 서버 MAC을 EVPN으로 배웠는가
     [통과] leaf1: 원격 MAC 1개를 EVPN으로 배움 (타입 2, fdb extern_learn)
   4) fdb에 손으로 적은 줄이 없는가
     [통과] leaf1: fdb에 손으로 넣은 줄이 없음 (VTEP은 EVPN이 넣은 것뿐)
   결과: 모두 통과
   ```
   (위는 2 ~ 4번 항목의 leaf1 줄만 옮긴 것임. 실제로는 1 ~ 5번 항목이 모두 나오고 항목마다 leaf1, leaf2 두 줄씩 나옴)  
   뜻: ping이 된다는 것만이 아니라 "VTEP과 MAC을 EVPN으로 배웠고 손으로 넣은 줄이 없는가"까지 확인함

10. 실습 환경을 끔  
    ```bash
    ./clab.sh destroy -t lab4.clab.yml --cleanup
    ```
    이렇게 나오면 성공: `Removed container name=clab-lab4-...` 줄이 나오고 `clab-lab4` 임시 폴더가 지워짐  
    뜻: 컨테이너 6개를 모두 지움

## 고장 연습
`./fault-demo.sh`는 고장을 하나씩 내고 `check.sh`를 돌린 뒤 바로 원래대로 되돌림. 마지막에 `복구 확인`으로 다시 검사함  
(아래 표는 2026-11-23 강사 PC에서 `fault-demo.sh`를 실제로 돌린 결과임)

| 번호 | 일부러 내는 고장 | 실패로 잡힌 검사 | ping |
|------|------------------|------------------|------|
| 1 | leaf2가 `advertise-all-vni`를 지움(자기 VNI와 VTEP을 EVPN으로 알리지 않음) | 2번(원격 VTEP 없음), 3번(원격 MAC 없음), 5번 | 안 됨 |
| 2 | leaf1이 `neighbor fabric activate`를 지움(EVPN 이웃을 켜지 않음) | 1번(EVPN 이웃 0개), 2번, 3번, 5번 | 안 됨 |
| 3 | leaf2가 자기 루프백(VTEP 주소)을 BGP로 알리지 않음 | 1번(상대 VTEP으로 가는 길이 없음), 5번 | 안 됨 |
| 4 | EVPN을 끄고 fdb에 상대 VTEP을 손으로 넣어 통신만 살림(편법) | 2번, 3번, 4번(손으로 넣은 줄이 있다고 알려 줌) | 됨 |

- 4번은 ping이 되는데도 검사는 실패함. 통신은 살렸지만 이 실습의 목표인 EVPN을 쓰지 않았기 때문임

## 막혔을 때
1. Docker Desktop이 켜져 있는지, `docker ps`에 `clab-lab4-`로 시작하는 컨테이너 6개가 있는지 확인함  
2. `./check.sh`가 실패하면 띄운 지 25초가 안 지났을 수 있으므로 잠시 기다린 뒤 다시 돌림  
3. 6번의 MAC 표에 `remote` 줄이 없으면 서버가 아직 말을 안 한 것임. 2번의 ping을 먼저 한 번 실행한 뒤 다시 확인함  
4. 실패 항목 아래에 나오는 `힌트:` 줄을 읽고 그대로 따라 해 봄  
5. 두 번 시도해도 안 되면 `./reset.sh`로 처음 상태로 되돌림

## 용어 풀이
이 실습에서 처음 나오는 용어만 적음. VTEP, VNI, VxLAN, fdb, 언더레이는 lab3의 용어 풀이를 참고함.

| 용어 | 쉬운 말 |
|------|---------|
| EVPN | VxLAN 터널의 상대 주소와 MAC 주소를 BGP로 알려 주는 방식. 손으로 적던 일을 자동으로 바꿈 |
| l2vpn evpn | BGP가 EVPN 경로를 주고받겠다고 켜는 설정 이름(주소 계열) |
| 타입 3 경로 | "나는 이 VNI의 VTEP임"이라는 알림. 상대 VTEP을 배우는 데 씀 |
| 타입 2 경로 | "이 MAC 주소는 내 뒤에 있음"이라는 알림. 상대 서버의 MAC을 배우는 데 씀 |
| advertise-all-vni | leaf가 가진 VNI를 모두 찾아 EVPN으로 알리라는 설정 |
| 경로 종류(type) | EVPN 경로에는 1 ~ 5번 종류가 있고, 이 실습은 2번과 3번만 씀 |
| HER | 브로드캐스트 같은 "모두에게" 패킷을 상대 VTEP마다 하나씩 복사해 보내는 방식(헤드엔드 복제) |
| extern_learn | 커널이 스스로 배운 것이 아니라 바깥 프로그램(FRR)이 넣어 준 fdb 줄이라는 표시 |
| nolearning | 터널로 들어온 패킷을 보고 MAC을 배우지 않게 하는 옵션. EVPN이 알려 준 것만 씀 |
| 로컬 MAC과 원격 MAC | 내 포트(eth3)에서 배운 MAC은 local, 상대 leaf가 알려 준 MAC은 remote |
