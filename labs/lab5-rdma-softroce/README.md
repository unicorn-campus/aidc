# lab5 Soft-RoCE로 RDMA 맛보기

## 이 실습에서 배우는 것
- lab3, lab4에서 VxLAN 터널이 UDP 4789로 오가는 것을 봤음. 이번에는 RDMA가 RoCEv2라는 이름으로 UDP 4791을 타고 오가는 것을 봄  
- RDMA 장치(`rxe0`)가 있는지, 어느 랜카드에 붙었는지, 그 장치로 두 서버가 실제로 자료를 주고받는지 확인함  
- lab4와 달라진 점: 이번에는 "통신이 되는가"가 아니라 "RDMA로 통신하고, 그 길이 UDP 4791인가"를 검사함  
- 이 실습의 숫자(속도, 시간)는 소프트웨어가 흉내 낸 값임. **실제 InfiniBand나 RoCE 랜카드의 성능이 아님**

## 왜 VM인가
lab1 ~ lab4는 컨테이너(containerlab)로 했지만, 이번 실습의 Soft-RoCE 기능(`rdma_rxe`)은 WSL2 커널에 들어 있지 않음.  
Docker Desktop도 같은 커널을 쓰므로 컨테이너로는 할 수 없어서, VirtualBox VM 두 대를 띄워 그 안의 Ubuntu 커널에서 함

## lab4와 달라진 점
| 구분 | lab4 (EVPN) | lab5 (Soft-RoCE) |
|------|-------------|------------------|
| 실습 장비 | containerlab 컨테이너 6개 | VirtualBox VM 2대(`rdma1`, `rdma2`) |
| 들어가는 법 | `docker exec clab-lab4-leaf1 ...` | `./vm-ssh.sh rdma1 "..."` |
| 터널 또는 통신 방식 | VxLAN, UDP 4789 | RDMA over RoCEv2, UDP 4791 |
| 검사가 보는 것 | VTEP과 MAC을 EVPN으로 배웠는가 | RDMA 장치가 있고, RDMA로 통신하고, 그 길이 UDP 4791인가 |
| 되돌리기 | 컨테이너를 지우고 다시 띄움 | VM을 스냅샷으로 되돌림(3 ~ 8분) |

## 이 실습이 진짜로 하는 것과 흉내 내는 것
| 주제 | 이 PC에서 |
|------|-----------|
| RDMA 장치 보기, GID 표 보기, rping과 pingpong 통신, UDP 4791 패킷 잡기 | 직접 함(실제 명령과 실제 출력) |
| RDMA 전송 자체 | 흉내 냄. 전용 랜카드 대신 VM의 CPU가 일함 |
| 대역폭과 지연 성능 | 이 PC에서 확인 못 함. 나오는 숫자는 흉내 값임 |
| InfiniBand(전용 스위치와 전용 랜카드) | 이 실습에서 직접 다루지 않음. 이론과 시연으로만 다룸 |

## 구성도와 주소표
```text
        Windows 11 호스트 (VirtualBox가 VM을 띄움)
        WSL2 터미널에서 ./reset.sh, ./vm-ssh.sh 등을 실행함

   +--------- VM rdma1 ---------+                  +--------- VM rdma2 ---------+
   | enp0s3  NAT (바깥 연결용)  |                  | enp0s3  NAT (바깥 연결용)  |
   | enp0s8  10.50.0.11/24 -----+-- aidc-rdma -----+----- enp0s8  10.50.0.12/24 |
   |   +- rxe0 (Soft-RoCE 장치) |  (내부 네트워크)  |   +- rxe0 (Soft-RoCE 장치) |
   +----------------------------+                  +----------------------------+

   RDMA 자료의 길: 프로그램(rping 등) -> 커널의 rdma_rxe -> UDP 4791 -> enp0s8 -> 내부망
```

| VM | 내부망 랜카드 | 주소 | RDMA 장치 | 호스트에서 SSH로 붙는 포트 |
|----|--------------|------|-----------|--------------------------|
| rdma1 | enp0s8 | 10.50.0.11/24 | rxe0 | 2251 |
| rdma2 | enp0s8 | 10.50.0.12/24 | rxe0 | 2252 |

- 내부망 이름은 `aidc-rdma`임. 이 이름이 같은 VM끼리만 통신하며 호스트 PC와 바깥에서는 보이지 않음  
- `enp0s3`은 바깥 인터넷으로 나가는 NAT 랜카드임. RDMA 장치는 반드시 내부망 쪽 `enp0s8`에 붙어 있어야 함  
- VM 사양은 CPU 2개, 메모리 2048MB, 디스크 10GB임

## 강사 준비(수업 전에 한 번)
수강생은 이 절을 하지 않음. 강사가 수업 전에 아래 두 가지를 해 둠.  
1. `./vm-up.sh`: VM 두 대를 만들고 꾸러미를 설치함. 약 15분이 걸림(처음부터 만들기 872초를 쟀음)  
2. `./snapshot-clean.sh`: "처음 상태"를 스냅샷으로 저장함. 약 1분이 걸림  

- 스냅샷에는 꾸러미가 깔려 있고 RDMA 장치(`rxe0`)만 없음. `./reset.sh`가 이 상태로 되돌린 뒤 장치를 붙여 줌  
- 스냅샷이 없으면 `./reset.sh`가 "스냅샷이 없음"이라며 멈춤

## 준비물
- VirtualBox가 설치되어 있어야 함(스크립트가 `C:\Program Files\Oracle\VirtualBox\VBoxManage.exe`를 씀)  
- 메모리 4GB 이상의 여유(VM 한 대가 2048MB)  
- 강사 준비가 끝나 있어야 함  
- Windows 터미널(또는 PowerShell)을 열고 `wsl`을 입력해 WSL을 엶. 이번 실습은 창이 두세 개 필요하므로 탭을 여러 개 열어 둠  
- 실습 폴더로 이동함. 아래 `<사용자>`는 내 Windows 사용자 이름으로 바꿈  
  ```bash
  cd /mnt/c/Users/<사용자>/class/aidc/labs/lab5-rdma-softroce
  ```
- 앞 실습(lab1 ~ lab4)이 떠 있어도 주소와 포트는 겹치지 않음

## 따라 하기
이 안내서의 출력은 2026-11-23 강사 PC에서 실제로 돌려 본 결과임. 포트 번호, QPN, PSN은 돌릴 때마다 바뀜.  
VM 안의 명령은 `./vm-ssh.sh <VM이름> "<명령>"`으로 돌림. 화면이 한참 조용해도 VM은 창 없이(headless) 도는 중이니 놀라지 않아도 됨.

1. 실습 환경을 띄움  
   ```bash
   ./reset.sh
   ```
   이렇게 나오면 성공: 3 ~ 8분 뒤 검사 항목이 줄줄이 나오고 마지막 검사 줄이 `결과: 모두 통과`임  
   뜻: VM 두 대를 끄고, 스냅샷으로 되돌리고, 다시 켜고, `cfg/setup-rxe.sh`로 RDMA 장치 `rxe0`을 붙인 뒤, 검사(`check.sh`)까지 한 번에 함.  
   걸리는 시간은 3 ~ 8분으로 들쭉날쭉함(실측 165, 168, 347, 498초). 부팅이 가끔 멈추는데 스크립트가 알아서 껐다 다시 켜니 기다림

2. 평범한 IP 통신부터 확인함  
   ```bash
   ./vm-ssh.sh rdma2 "ping -c 3 10.50.0.11"
   ```
   이렇게 나오면 성공: `3 packets transmitted, 3 received, 0% packet loss`  
   ```text
   3 packets transmitted, 3 received, 0% packet loss, time 2015ms
   rtt min/avg/max/mdev = 2.079/2.653/2.945/0.405 ms
   ```
   뜻: 두 VM이 내부망으로 보이는 상태임. 아직 RDMA가 아니라 보통의 IP 통신임(핵심 줄만 옮김)

3. RDMA 장치를 확인함  
   ```bash
   ./vm-ssh.sh rdma1 "rdma link show"
   ```
   이렇게 나오면 성공: `state ACTIVE`이고 `netdev enp0s8`임(rdma2에서 해도 같음)  
   ```text
   link rxe0/1 state ACTIVE physical_state LINK_UP netdev enp0s8
   ```
   뜻: RDMA 장치 `rxe0`이 켜져 있고 내부망 랜카드 `enp0s8`에 붙어 있음. 장치가 있어도 엉뚱한 랜카드에 붙어 있으면 통신하지 못함

4. 장치가 이더넷 위에 올라가 있는지 봄  
   ```bash
   ./vm-ssh.sh rdma1 "ibv_devinfo -d rxe0"
   ```
   이렇게 나오면 성공: `transport`는 `InfiniBand`, `link_layer`는 `Ethernet`임(핵심 줄만 옮김)  
   ```text
   hca_id:	rxe0
   	transport:			InfiniBand (0)
   		port:	1
   			state:			PORT_ACTIVE (4)
   			link_layer:		Ethernet
   ```
   뜻: RoCE는 "InfiniBand 방식의 전송을 이더넷 선 위에 올린 것"이라서 두 단어가 함께 나옴

5. GID 표에서 RoCEv2 자리를 찾음  
   ```bash
   ./vm-ssh.sh rdma1 'for f in /sys/class/infiniband/rxe0/ports/1/gids/*; do \
     i=$(basename $f); g=$(cat $f); \
     [ "$g" = "0000:0000:0000:0000:0000:0000:0000:0000" ] && continue; \
     echo "$i $g $(cat /sys/class/infiniband/rxe0/ports/1/gid_attrs/types/$i)"; done'
   ```
   이렇게 나오면 성공: 0번과 1번 줄이 나오고 둘 다 끝이 `RoCE v2`임. 1번에 내부망 주소가 들어 있음  
   ```text
   0 fe80:0000:0000:0000:0a00:27ff:fe5a:0111 RoCE v2
   1 0000:0000:0000:0000:0000:ffff:0a32:000b RoCE v2
   ```
   뜻: GID는 RDMA에서 상대를 찾는 주소임. 1번의 `ffff:0a32:000b`는 IPv4 주소 10.50.0.11(`0a32000b`)을 IPv6 모양으로 적은 것임.  
   IPv4로 통신하는 시험에서는 이 1번을 씀(아래 pingpong의 `-g 1`).  
   이 명령은 빈 자리를 하나씩 읽어서 VM 한 대에 1분 가까이 걸릴 수 있음(`check.sh`는 더 빠른 방법을 씀)

6. rping으로 RDMA 통신을 함(창 두 개)  
   ```bash
   # 창1 (서버)
   ./vm-ssh.sh rdma1 "rping -s -a 10.50.0.11 -C 5 -v -S 64"
   ```
   ```bash
   # 창2 (손님). 서버가 뜬 뒤 몇 초 있다가 실행함
   ./vm-ssh.sh rdma2 "rping -c -a 10.50.0.11 -C 5 -v -S 64"
   ```
   이렇게 나오면 성공: 손님 창에 `ping data: rdma-ping-0:` 부터 `rdma-ping-4:` 까지 다섯 줄이 나옴  
   ```text
   ping data: rdma-ping-0: ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqr
   ping data: rdma-ping-1: BCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrs
   ping data: rdma-ping-2: CDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrst
   ping data: rdma-ping-3: DEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstu
   ping data: rdma-ping-4: EFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuv
   ```
   뜻: `rping`은 RDMA용 ping임. `-s`는 서버, `-c`는 손님, `-C 5`는 5번, `-S 64`는 한 번에 64바이트임.  
   서버 창에도 같은 다섯 줄이 `server ping data:`로 찍힘.  
   **끝낸 뒤 서버가 아직 떠 있으면 반드시 끝냄**(손님이 끝나도 서버는 다음 손님을 기다림). 새 창에서:  
   ```bash
   ./vm-ssh.sh rdma1 "sudo pkill -x rping"
   ```

7. ibv_rc_pingpong으로 한 번 더 시험함(창 두 개, 선택)  
   ```bash
   # 창1 (서버)
   ./vm-ssh.sh rdma1 "ibv_rc_pingpong -d rxe0 -g 1 -n 10 -s 1024"
   ```
   ```bash
   # 창2 (손님)
   ./vm-ssh.sh rdma2 "ibv_rc_pingpong -d rxe0 -g 1 -n 10 -s 1024 10.50.0.11"
   ```
   이렇게 나오면 성공: `local address` 줄과 `20480 bytes`, `10 iters` 줄이 나옴(손님 창, 핵심 줄만 옮김. `remote address` 줄도 함께 나옴)  
   ```text
     local address:  LID 0x0000, QPN 0x000012, PSN 0xa20756, GID ::ffff:10.50.0.12
   20480 bytes in 0.03 seconds = 6.08 Mbit/sec
   10 iters in 0.03 seconds = 2693.90 usec/iter
   ```
   뜻: `-g 1`은 5번에서 찾은 GID 1번을 쓰라는 뜻이고 `-n 10`은 10번만 주고받으라는 뜻임.  
   `LID 0x0000`은 InfiniBand 주소를 쓰지 않고 GID(IP)로 상대를 찾는다는 뜻임.  
   **`-n 10`을 빼지 않음.** 기본값(1000번)은 이 PC에서 끝나지 않거나 VM이 멈춘 적이 있음.  
   속도(6.08 Mbit/sec)와 시간(2693.90 usec)은 소프트웨어 흉내 값이며 실제 장비 성능이 아님

8. 그 통신이 UDP 4791로 오가는지 패킷을 잡아 봄(창 세 개)  
   ```bash
   # 창1: 먼저 패킷 잡기를 시작함 (10개를 잡으면 끝남)
   ./vm-ssh.sh rdma2 "sudo tcpdump -ni enp0s8 -c 10 udp port 4791"
   ```
   창1을 띄운 직후, 창2와 창3에서 6번의 rping 서버와 손님을 차례로 다시 돌림(서버가 먼저).  
   이렇게 나오면 성공: 받는 쪽 포트가 `.4791`인 줄이 나오고 마지막에 `10 packets captured`가 보임(핵심 줄만 옮김)  
   ```text
   IP 10.50.0.12.55410 > 10.50.0.11.4791: UDP, length 280
   10 packets captured
   ```
   뜻: RDMA 자료가 UDP 4791 패킷에 담겨 내부망을 오감. 반대 방향(10.50.0.11 에서 10.50.0.12로)도 잡힘.  
   lab3, lab4의 VxLAN은 UDP 4789였음. 숫자 하나 차이지만 전혀 다른 기술임.  
   `length` 값은 시험마다 다름. 끝낸 뒤 6번처럼 서버를 끝냄

9. 대역폭 숫자를 봄(선택, 창 두 개)  
   ```bash
   # 창1 (서버)
   ./vm-ssh.sh rdma1 "ib_send_bw -d rxe0 -x 1 -n 200 -s 1024 -F"
   ```
   ```bash
   # 창2 (손님)
   ./vm-ssh.sh rdma2 "ib_send_bw -d rxe0 -x 1 -n 200 -s 1024 -F 10.50.0.11"
   ```
   이렇게 나오면 성공: 평균 대역폭이 1 MB/sec 안팎으로 나옴(실측 1.07). 실제 RDMA 장비는 이보다 훨씬 빠름  
   ```text
    #bytes     #iterations    BW peak[MB/sec]    BW average[MB/sec]   MsgRate[Mpps]
    1024       200              1.07               1.07              0.001094
   ```
   뜻: **이 숫자는 흉내 값이며 실제 장비 성능이 아님.** 전용 랜카드가 아니라 VM의 CPU가 RDMA를 흉내 내기 때문에 느림.  
   `ib_write_bw`로 잰 값도 1.13 MB/sec로 비슷했음

10. 검사를 돌림  
    ```bash
    ./check.sh
    ```
    이렇게 나오면 성공: 항목 5개가 모두 `[통과]`이고 마지막 줄이 `결과: 모두 통과`임. 약 15초 걸림  
    ```text
      [통과] rdma1 -> 10.50.0.12 내부망 통신 정상
      [통과] rdma2 -> 10.50.0.11 내부망 통신 정상
      [통과] rdma1: rxe0 이 ACTIVE 이고 내부망 랜카드 enp0s8 에 붙음
      [통과] rdma2: rxe0 이 ACTIVE 이고 내부망 랜카드 enp0s8 에 붙음
    3) rxe0 의 GID 표에 내부망 IP 를 담은 RoCEv2 자리가 있는가
      [통과] rdma1: GID 1번이 RoCE v2 이고 내부망 주소 10.50.0.11 를 담음 (0000:0000:0000:0000:0000:ffff:0a32:000b)
      [통과] rdma2: GID 1번이 RoCE v2 이고 내부망 주소 10.50.0.12 를 담음 (0000:0000:0000:0000:0000:ffff:0a32:000c)
      [통과] rdma2 -> rdma1(10.50.0.11) rping 으로 5번 주고받기 성공
    5) 그 통신이 RoCEv2(UDP 4791)로 내부망을 오가는가
      [통과] 10.50.0.12 <-> 10.50.0.11 사이에서 UDP 4791 패킷 14개 잡음 (보냄 7개, 받음 7개)
    결과: 모두 통과
    ```
    (위는 `reset.sh` 끝에서 실제로 나온 결과이며, 1, 2, 4번 항목의 제목 줄은 옮기지 않았음. 패킷 개수는 바뀔 수 있음)  
    뜻: ping이 된다는 것만이 아니라 "RDMA 장치가 있고, RDMA로 통신했고, 그 길이 UDP 4791인가"까지 확인함.  
    검사가 rping을 직접 돌리므로 6, 8번에서 띄운 rping은 끝나 있어도, 떠 있어도 상관없음(검사가 먼저 정리함)

11. 실습 환경을 끔  
    ```bash
    ./vm-down.sh
    ```
    뜻: 두 VM을 끄기만 함. 스크립트는 마지막에 `끝. 남은 VM:`과 VM 목록을 찍도록 만들어져 있음(이 안내서를 쓰며 돌려 보지는 않아 출력은 미확인).  
    다음에 다시 시작할 때는 1번의 `./reset.sh`부터 함

## 고장 연습
`./fault-demo.sh`는 고장을 하나씩 내고 `check.sh`를 돌린 뒤 바로 원래대로 되돌림. 마지막에 `되돌린 뒤 확인`으로 다시 검사함.  
전체는 약 7분 30초가 걸리고, `./fault-demo.sh 4`처럼 번호를 주면 그 고장만 함(4번만 약 2분).  
(아래 표는 2026-11-23 강사 PC에서 `fault-demo.sh`를 실제로 돌린 결과임)

| 번호 | 일부러 내는 고장 | 통신 | 실패로 잡힌 검사 |
|------|------------------|------|------------------|
| 1 | rdma1의 `rxe0`을 지움(`rdma link delete rxe0`) | 내부망 ping은 됨, RDMA는 안 됨 | 2, 3, 4, 5번 |
| 2 | rdma2의 내부망 랜카드 선을 뽑음 | 안 됨 | 1, 2, 3, 4, 5번 |
| 3 | rdma1의 `rxe0`을 NAT 랜카드(`enp0s3`)에 붙임 | IP 통신은 됨, RDMA는 안 됨 | 2, 3, 4, 5번 |
| 4 | 편법: 양쪽 `rxe0`을 siw(iWARP 흉내)로 바꿔치기 | rping이 됨 | 3, 5번 |

- 4번은 rping이 성공하는데도 검사는 실패함. 이름도 `rxe0`이고 내부망 랜카드에 붙었지만 RoCE가 아니라서 GID 표(3번)에  
  RoCEv2 자리가 없고, 자료가 UDP 4791이 아니라 TCP로 가기 때문(5번)임. 통신만 되면 되는 것이 아니라 어떤 길로 가는가가 이 실습의 목표임  
- 1번은 내부망 ping(검사 1번)이 통과하므로, RDMA 장치만 없을 때 ping만 봐서는 못 알아낸다는 것을 보여 줌

## 주의
- **RDMA 시험 프로그램(rping 등)이 돌고 있는 중에 `rdma link delete rxe0`을 하지 않음.** VM 커널이 멈춤(kernel panic을 실제로 봄).  
  시험 프로그램을 끝낸 뒤 장치를 지움. `fault-demo.sh`와 `check.sh`는 이 순서를 지키도록 만들어져 있음  
- **`ibv_rc_pingpong`은 `-n 10`처럼 횟수를 줄여서 돌림.** 기본값(1000번)에서는 VM이 멎은 적이 있음  
- 부팅이 가끔 멈춤. `reset.sh`가 알아서 껐다 다시 켜므로 기다림. 되돌리기는 3 ~ 8분 걸릴 수 있음  
- 모든 속도와 시간 숫자는 흉내 값임. 실제 장비와 비교하지 않음  
- 위 시간과 출력은 강사 PC(메모리 32GB) 기준이며, 강의장 PC에서의 동작은 아직 확인하지 못함(미확인)

## 막혔을 때
1. `VBoxManage 를 찾지 못함`이 나오면 VirtualBox가 설치되어 있는지, 명령을 WSL 안에서 치고 있는지 확인함  
2. `./reset.sh`가 `스냅샷이 없음`이라며 멈추면 강사에게 `./snapshot-clean.sh`를 한 번 돌려 달라고 함  
3. `./reset.sh`가 5분 넘게 조용해도 멈춘 것이 아닐 수 있음(최대 8분 정도 걸린 적이 있음). 스크립트가 멈춘 VM은 스스로 다시 켬  
4. `./check.sh`가 실패하면 항목 아래의 `힌트:` 줄을 읽고 그대로 따라 해 봄. 켠 지 얼마 안 됐으면 1분 뒤에 다시 돌림  
5. 3번(`rdma link show`)에 아무것도 안 나오면 장치가 없는 것임. `./reset.sh`를 다시 돌림  
6. rping 서버가 안 끝나면 `./vm-ssh.sh rdma1 "sudo pkill -x rping"`으로 끝냄(rdma2도 같음)  
7. 두 번 시도해도 안 되면 `./reset.sh`로 처음 상태로 되돌림

## 용어 풀이
| 용어 | 쉬운 말 |
|------|---------|
| RDMA | 상대 컴퓨터의 메모리로 자료를 곧바로 옮기는 방식. 원래는 전용 랜카드가 CPU를 거치지 않고 해 주어서 빠름 |
| InfiniBand | RDMA를 위해 만든 전용 네트워크(전용 랜카드와 전용 스위치). 이 실습에서 직접 다루지 않음 |
| RoCE | InfiniBand 방식의 RDMA를 일반 이더넷 선 위에 올린 것. "이더넷 위의 RDMA" |
| RoCEv2 | RoCE의 두 번째 판. RDMA 자료를 UDP 패킷(받는 쪽 포트 4791)에 담아 보내서 IP 망을 건널 수 있음 |
| Soft-RoCE(rxe) | 전용 랜카드 없이 일반 랜카드 위에서 RDMA를 흉내 내는 리눅스 기능. 이름은 `rdma_rxe`, 장치 이름은 `rxe0`. 일은 CPU가 함 |
| iWARP(siw) | 이더넷 위의 또 다른 RDMA 방식. UDP가 아니라 TCP로 감. 이 실습에서는 편법 고장(4번)에만 나옴 |
| rdma link | RDMA 장치를 만들고(`add`) 지우고(`delete`) 보는(`show`) 명령 |
| GID | RDMA에서 상대를 찾는 주소. IP 주소를 IPv6 모양으로 적은 것이 들어감. 표에 여러 번호가 있고 RoCEv2 자리를 골라 씀 |
| LID | InfiniBand에서 쓰는 주소. RoCE에서는 쓰지 않아 `0x0000`으로 나옴 |
| QP(큐 페어) | RDMA 통신의 출입구. 보내는 줄과 받는 줄 한 쌍으로 이루어짐. 번호가 QPN임 |
| PSN | 패킷에 붙는 순서 번호. 시험마다 다르게 나옴 |
| rping | RDMA로 하는 ping. 서버(`-s`)와 손님(`-c`)이 짝을 이뤄 글자를 주고받음 |
| ibv_rc_pingpong | 큐 페어 정보를 맞춰 보며 RDMA로 주고받는 시험 프로그램 |
| perftest(ib_send_bw) | RDMA 대역폭을 재는 프로그램 묶음. 이 실습의 값은 흉내 값임 |
| tcpdump | 랜카드를 지나는 패킷을 잡아서 보여 주는 도구 |
| NAT 랜카드(enp0s3) | VM이 바깥 인터넷으로 나갈 때 쓰는 랜카드. RDMA 장치는 여기에 붙이지 않음 |
| 내부 네트워크(aidc-rdma) | 이름이 같은 VM끼리만 통신되는 VirtualBox의 닫힌 네트워크 |
| 스냅샷 | VM의 어느 순간 상태를 저장해 두었다가 되돌리는 기능. `reset.sh`가 이것으로 되돌림 |
| headless | 화면 창 없이 VM을 돌리는 방식. 창이 안 보여도 정상임 |
