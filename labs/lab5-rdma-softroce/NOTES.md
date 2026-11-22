# lab5 Soft-RoCE 로 RDMA 맛보기 (지피니 작업 기록)

## 목표
- lab3 과 lab4 에서 본 VxLAN(UDP 4789)에 이어, RDMA 가 RoCEv2(UDP 4791) 위로 오가는 것을 눈으로 봄
- RDMA 장치를 만들고(`rdma link add`), RDMA 전용 프로그램(rping, ibv_rc_pingpong, perftest)이 도는 것을 확인함
- "CPU 를 거치지 않는 메모리 직접 전송"이라는 개념을 손으로 만져 보되, 성능은 실제 장비와 다르다는 점을 함께 배움

## 이 실습이 진짜로 하는 것과 흉내 내는 것

| 주제 | 이 PC 에서 | 근거 | 교재에 적을 문장 |
|------|-----------|------|------------------|
| RDMA 장치 만들기와 보기(`rdma link`, `ibv_devices`, GID 표) | 직접 함 | VM 안에서 실제로 실행해 출력을 받음 | 실제 명령과 출력이 그대로임 |
| RoCEv2 패킷이 UDP 4791 로 오감 | 직접 함 | `tcpdump` 로 양방향 UDP 4791 패킷을 잡음 | 실제 패킷을 잡아 본 결과임 |
| RDMA 프로그램 통신(rping, ibv_rc_pingpong, ib_send_bw) | 직접 함 | 두 VM 사이에서 성공 출력을 받음 | 실제 RDMA 라이브러리로 통신함 |
| RDMA 전송 자체(큐 페어, 메모리 등록, 원격 쓰기) | 흉내 냄 | `rdma_rxe` 가 전용 랜카드 대신 커널에서 처리함 | 순서는 같으나 일하는 주체가 랜카드가 아니라 CPU 임 |
| RDMA 의 대역폭과 지연 성능 | 이론과 시연만 | 측정값이 소프트웨어 흉내 값이며 가상 랜카드를 거침 | 이 PC 에서 확인 못 함 |
| 전용 랜카드의 커널 우회(Kernel Bypass)로 얻는 CPU 절감 | 이론과 시연만 | Soft-RoCE 는 오히려 CPU 를 더 씀 | 이 PC 에서 확인 못 함 |
| InfiniBand(전용 패브릭, Subnet Manager, LID 주소) | 이론과 시연만 | 전용 HCA 와 InfiniBand 스위치가 필요함 | 이 PC 에서 확인 못 함 |
| 무손실 이더넷(PFC, ECN, DCQCN) | 이론과 시연만 | 스위치의 우선순위 흐름 제어 설정이 필요함 | 이 PC 에서 확인 못 함 |
| GPUDirect RDMA, NCCL 의 RDMA 통신 | 이론과 시연만 | GPU 와 RDMA 랜카드가 함께 필요함 | 이 PC 에서 확인 못 함 |

> 측정한 모든 숫자는 소프트웨어로 흉내 낸 값임. **실제 InfiniBand 나 RoCE 랜카드의 성능이 아님.**

## 왜 containerlab 이 아니라 VM 인가
- WSL2 커널(`6.18.58.1-microsoft-standard-WSL2`)에는 `rdma_rxe` 와 `siw` 모듈이 없음
  (`modprobe: FATAL: Module rdma_rxe not found`). Docker Desktop 도 같은 커널을 쓰므로 컨테이너 방식으로는 불가
- 그래서 VirtualBox VM 두 대를 띄우고, 그 안의 Ubuntu 커널에서 Soft-RoCE 를 씀
- lab1 ~ lab4 는 containerlab 그대로 두고, lab5 만 VM 을 씀

## 구성도

```text
     Windows 11 호스트 (VirtualBox)
     ├─ WSL2 : 여기서 vm-up.sh, vm-ssh.sh 를 실행함
     │
     ├─ VM rdma1                              ├─ VM rdma2
     │   enp0s3  NAT (10.0.2.15)              │   enp0s3  NAT (10.0.2.15)
     │     └ 호스트 2251 -> VM 22 (SSH)       │     └ 호스트 2252 -> VM 22 (SSH)
     │   enp0s8  10.50.0.11/24 ---------------+---  enp0s8  10.50.0.12/24
     │     └ rxe0 (Soft-RoCE 장치)            │     └ rxe0 (Soft-RoCE 장치)
     │                                        │
     └─ VirtualBox 내부 네트워크 "aidc-rdma" (호스트와 바깥에서 보이지 않음)

   RDMA 트래픽 경로:
     프로그램(rping 등) -> libibverbs -> 커널 rdma_rxe -> UDP 4791 -> enp0s8 -> 내부망
     즉 겉보기에는 평범한 UDP 패킷이며, 그 안에 RoCEv2 헤더와 RDMA 내용이 들어 있음
```

## 주소표와 VM 사양

| 항목 | rdma1 | rdma2 |
|------|-------|-------|
| 내부망 주소(enp0s8) | 10.50.0.11/24 | 10.50.0.12/24 |
| 내부망 랜카드 MAC | 08:00:27:5a:01:11 | 08:00:27:5a:01:12 |
| NAT 랜카드 MAC | 08:00:27:5a:01:01 | 08:00:27:5a:01:02 |
| 호스트 SSH 포트 | 2251 | 2252 |
| RDMA 장치 | rxe0 | rxe0 |
| node GUID | 0a00:27ff:fe5a:0111 | 0a00:27ff:fe5a:0112 |

- VM 사양: CPU 2개, 메모리 2048MB, 디스크 10GB(실제로 쓰는 양은 약 1.8GB)
- 원본 이미지: Ubuntu 24.04.5 LTS 공식 클라우드 이미지 OVA, 커널 `6.8.0-147-generic`
- 내부 네트워크 이름 `aidc-rdma`. 다른 실습의 `172.30.30.0/24`, `10.0.0.0/24`, `10.10.10.0/24` 와 겹치지 않음
- 호스트 포트 2251, 2252 는 다른 실습에서 쓰지 않음
- VM 파일 위치: `.cache/vms/rdma1`, `.cache/vms/rdma2` (git 에 올라가지 않음)
- SSH 키: `.cache/lab5-keys/id_ed25519` (git 에 올라가지 않음). 비밀번호 로그인은 꺼 둠

## 파일

| 파일 | 내용 |
|------|------|
| `lab5.env` | 이름, 주소, 포트, 메모리, MAC 등 값만 모아 둔 곳. 바꿀 값은 여기만 고침 |
| `_common.sh` | 세 스크립트가 함께 쓰는 함수(VM 찾기, SSH, 기다리기). 직접 실행하지 않음 |
| `vm-up.sh` | VM 을 만들고 켜고 Soft-RoCE 까지 설정함 |
| `vm-down.sh` | VM 을 끔. `--delete` 를 붙이면 디스크까지 지움 |
| `vm-ssh.sh` | VM 안으로 들어가거나 명령 하나를 돌림 |
| `cloud-init/user-data.tmpl` | 첫 부팅 때 만들 사용자, 넣을 꾸러미, 올릴 커널 모듈 |
| `cloud-init/meta-data.tmpl` | VM 이름 |
| `cloud-init/network-config.tmpl` | 랜카드 두 장의 주소(MAC 으로 찾아 붙임) |
| `cfg/setup-rxe.sh` | VM 안에서 도는 Soft-RoCE 설정. 모듈 올리기, `rdma link add`, systemd 등록, GID 표 보기 |

## 띄우기와 내리기

```bash
# WSL 안에서
cd /mnt/c/Users/<사용자>/class/aidc/labs/lab5-rdma-softroce
./vm-up.sh                 # 두 대 만들고 Soft-RoCE 까지 설정 (처음에는 10분 넘게 걸림)
./vm-ssh.sh rdma1          # VM 안으로 들어가기
./vm-down.sh               # 끄기만 (다음 수업에 그대로 다시 켬)
./vm-down.sh --delete      # 디스크까지 지우기
```

- 처음 만들 때는 인터넷에서 꾸러미를 받으므로 시간이 걸림. 두 번째부터는 끄고 켜기만 하면 1분 안쪽임
- `vm-up.sh` 를 다시 실행해도 이미 있는 VM 은 건너뜀. 다시 만들려면 `--delete` 로 먼저 지움

## 확인 명령과 정상일 때 출력 (2026-11-23 강사 PC 실측)

> QPN, PSN, 포트 번호는 돌릴 때마다 바뀜. GID 와 주소는 고정임.

1. 내부망 통신(평범한 IP): `./vm-ssh.sh rdma2 "ping -c 3 10.50.0.11"`
   ```text
   3 packets transmitted, 3 received, 0% packet loss, time 2015ms
   rtt min/avg/max/mdev = 2.079/2.653/2.945/0.405 ms
   ```

2. RDMA 장치가 보임: `./vm-ssh.sh rdma1 "rdma link show"`
   ```text
   link rxe0/1 state ACTIVE physical_state LINK_UP netdev enp0s8
   ```

3. 장치 목록: `./vm-ssh.sh rdma1 "ibv_devices"`
   ```text
       device          	   node GUID
       ------          	----------------
       rxe0            	0a0027fffe5a0111
   ```

4. 장치 자세히: `./vm-ssh.sh rdma1 "ibv_devinfo -d rxe0"`
   ```text
   hca_id:	rxe0
   	transport:			InfiniBand (0)
   	phys_port_cnt:			1
   		port:	1
   			state:			PORT_ACTIVE (4)
   			max_mtu:		4096 (5)
   			active_mtu:		1024 (3)
   			link_layer:		Ethernet
   ```
   - `transport` 가 InfiniBand 로 나오지만 `link_layer` 는 Ethernet 임. RoCE 는 "이더넷 위에 올린 InfiniBand 전송"이라는 뜻

5. GID 표에서 RoCEv2 자리 찾기:
   ```bash
   ./vm-ssh.sh rdma1 'for f in /sys/class/infiniband/rxe0/ports/1/gids/*; do \
     i=$(basename $f); g=$(cat $f); \
     [ "$g" = "0000:0000:0000:0000:0000:0000:0000:0000" ] && continue; \
     echo "$i $g $(cat /sys/class/infiniband/rxe0/ports/1/gid_attrs/types/$i)"; done'
   ```
   ```text
   0 fe80:0000:0000:0000:0a00:27ff:fe5a:0111 RoCE v2
   1 0000:0000:0000:0000:0000:ffff:0a32:000b RoCE v2
   ```
   - 1번의 `0000:ffff:0a32:000b` 는 IPv4 주소 10.50.0.11 을 IPv6 모양으로 적은 것(`0a32000b` = 10.50.0.11)
   - 그래서 IPv4 로 통신하는 시험에는 **1번**을 씀(`-g 1` 또는 `-x 1`)

6. rping 통신(RDMA CM 을 쓰는 가장 쉬운 시험). 창 두 개가 필요함
   ```bash
   # 창1 (서버)
   ./vm-ssh.sh rdma1 "rping -s -a 10.50.0.11 -C 5 -v -S 64"
   # 창2 (손님)
   ./vm-ssh.sh rdma2 "rping -c -a 10.50.0.11 -C 5 -v -S 64"
   ```
   손님 쪽 정상 출력:
   ```text
   ping data: rdma-ping-0: ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqr
   ping data: rdma-ping-1: BCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrs
   ping data: rdma-ping-2: CDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrst
   ping data: rdma-ping-3: DEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstu
   ping data: rdma-ping-4: EFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuv
   ```
   서버 쪽에도 같은 다섯 줄이 `server ping data:` 로 찍힘

7. ibv_rc_pingpong(큐 페어를 손으로 맞춰 보는 시험). **횟수를 줄여서 돌림**
   ```bash
   # 창1 (서버)
   ./vm-ssh.sh rdma1 "ibv_rc_pingpong -d rxe0 -g 1 -n 10 -s 1024"
   # 창2 (손님)
   ./vm-ssh.sh rdma2 "ibv_rc_pingpong -d rxe0 -g 1 -n 10 -s 1024 10.50.0.11"
   ```
   ```text
     local address:  LID 0x0000, QPN 0x000015, PSN 0x823468, GID ::ffff:10.50.0.12
     remote address: LID 0x0000, QPN 0x000013, PSN 0xe20ca1, GID ::ffff:10.50.0.11
   20480 bytes in 0.04 seconds = 4.60 Mbit/sec
   10 iters in 0.04 seconds = 3561.10 usec/iter
   ```
   - `LID 0x0000` 은 InfiniBand 의 주소 체계를 쓰지 않는다는 뜻. 대신 GID(IP 주소)로 상대를 찾음
   - 기본값인 1000회(`-n` 없이)로 돌리면 이 PC 에서 끝나지 않음. 아래 「막힌 점」 참조

8. RoCEv2 패킷 확인(UDP 4791). 창 두 개가 필요함
   ```bash
   # 창1: 패킷 잡기
   ./vm-ssh.sh rdma2 "sudo tcpdump -ni enp0s8 -c 12 udp port 4791"
   # 창2: 위 6번이나 7번 시험을 돌림
   ```
   ```text
   17:22:28.544295 IP 10.50.0.12.49475 > 10.50.0.11.4791: UDP, length 1040
   17:22:28.552955 IP 10.50.0.11.49475 > 10.50.0.12.4791: UDP, length 20
   17:22:28.552955 IP 10.50.0.11.49475 > 10.50.0.12.4791: UDP, length 1040
   12 packets captured
   ```
   - 받는 쪽 포트가 항상 **4791** 임. 이것이 RoCEv2 의 표시임
   - `length 1040` 은 1024바이트 자료 + RoCE 헤더, `length 20` 은 잘 받았다는 응답(ACK)
   - lab3 과 lab4 의 VxLAN 은 UDP 4789 였음. 숫자 하나 차이지만 전혀 다른 기술임

9. 대역폭 재기(흉내 값). 창 두 개가 필요함
   ```bash
   # 창1 (서버)
   ./vm-ssh.sh rdma1 "ib_send_bw -d rxe0 -x 1 -n 200 -s 1024 -F"
   # 창2 (손님)
   ./vm-ssh.sh rdma2 "ib_send_bw -d rxe0 -x 1 -n 200 -s 1024 -F 10.50.0.11"
   ```
   ```text
    #bytes     #iterations    BW peak[MB/sec]    BW average[MB/sec]   MsgRate[Mpps]
    1024       200              1.07               1.07   		   0.001094
   ```
   - **이 숫자는 소프트웨어로 흉내 낸 값이며 실제 RDMA 랜카드 성능이 아님**

## 측정값 (2026-11-23 강사 PC 실측)

| 항목 | 값 | 비고 |
|------|-----|------|
| 처음 만들 때 cloud-init 끝날 때까지 | 약 298초 | 커널 모듈 꾸러미 114MB 내려받기 포함 |
| 끄고 다시 켤 때 SSH 열릴 때까지 | 약 25초 | |
| 끄고 다시 켤 때 cloud-init 끝날 때까지 | 약 50초 | rxe0 도 systemd 로 자동 복구됨 |
| 두 대 지우기(`vm-down.sh --delete`) | 18초 | |
| 지우고 처음부터 다시 만들기(두 대, `vm-up.sh`) | 872초(14분 32초) | rdma1 이 첫 부팅에서 멈춰 한 번 다시 켠 시간 포함 |
| 내부망 ping 왕복 시간 | 평균 2.65ms | 실제 장비는 마이크로초 단위. 가상 랜카드 때문에 느림 |
| ibv_rc_pingpong 한 번 왕복 | 약 3561us | 흉내 값 |
| ib_send_bw 평균 대역폭 | 1.07 MB/s | 흉내 값 |
| ib_write_bw 평균 대역폭 | 1.13 MB/s | 흉내 값 |
| VM 한 대가 쓰는 디스크 | 약 1.8GB | 10GB 중 실제로 쓰는 양 |

> 위 성능 숫자는 모두 **소프트웨어 흉내 값**이며 실제 InfiniBand 나 RoCE 장비의 성능이 아님.
> 이 PC 는 WSL2 와 Docker Desktop 이 하드웨어 가상화를 이미 잡고 있어 VirtualBox 가 느린 방식으로 도는 점도 겹침.

## 다시 만들기 확인 (2026-11-23 실측)

- `./vm-down.sh --delete` 로 두 대를 지운 뒤(18초) `./vm-up.sh` 로 처음부터 다시 만듦(872초)
- 다시 만든 VM 에서 아래가 모두 처음과 같았음

| 확인한 것 | 처음 | 다시 만든 뒤 |
|-----------|------|--------------|
| 장치 이름과 상태 | `rxe0/1 state ACTIVE ... netdev enp0s8` | 같음 |
| node GUID | rdma1 `0a0027fffe5a0111`, rdma2 `...0112` | 같음(MAC 을 고정했기 때문) |
| GID 1번 종류 | `RoCE v2`, `...:ffff:0a32:000b` | 같음 |
| rping 5회 | 성공(끝코드 0) | 성공(끝코드 0) |
| ibv_rc_pingpong `-n 10` | 성공(3561us/회) | 성공(2693us/회) |
| UDP 4791 패킷 | 양방향으로 잡힘 | 양방향으로 잡힘 |

- 다시 만드는 동안 rdma1 이 첫 부팅에서 한 번 멈췄고, `vm-up.sh` 가 스스로 전원을 껐다 켜서 넘어감
- 같은 시간에 돌던 lab2 containerlab 컨테이너 6개와 다른 프로젝트 컨테이너 3개는 건드리지 않았고 그대로 살아 있었음

## 랩니 검사 항목 제안

> `./vm-ssh.sh <VM이름> "<명령>"` 으로 VM 안의 명령을 돌릴 수 있음.
> "통신이 되는가"가 아니라 "RDMA 로 통신하는가"를 보는 항목으로 골랐음.

1. **두 VM 이 살아 있는가**  
   `VBoxManage.exe list runningvms` 에 `rdma1` 과 `rdma2` 가 있고, 양쪽 `./vm-ssh.sh <이름> true` 가 성공함
2. **RDMA 장치가 올라왔는가**  
   `./vm-ssh.sh rdma1 "rdma link show"` → `link rxe0/1 state ACTIVE physical_state LINK_UP netdev enp0s8`  
   (`state ACTIVE` 와 `netdev enp0s8` 두 가지를 함께 봄. 장치만 있고 랜카드에 안 붙으면 통신 못 함)
3. **RoCEv2 GID 가 있는가**  
   `/sys/class/infiniband/rxe0/ports/1/gid_attrs/types/1` 이 `RoCE v2` 이고,  
   `gids/1` 이 내부망 IP 를 IPv6 모양으로 담고 있음(rdma1 이면 `...:ffff:0a32:000b`)
4. **RDMA 로 실제 통신이 되는가**  
   rdma1 에서 `rping -s -a 10.50.0.11 -C 5 -v -S 64` 를 띄우고 rdma2 에서 손님(`-c`)을 돌려,  
   손님 쪽에 `ping data: rdma-ping-0:` ~ `rdma-ping-4:` 다섯 줄이 나오고 끝코드가 0 임
5. **그 통신이 RoCEv2(UDP 4791)로 오가는가**  
   4번을 돌리는 동안 `sudo tcpdump -ni enp0s8 -c 10 udp port 4791` 가 10개를 잡고,  
   잡힌 줄의 받는 쪽 포트가 모두 `.4791` 임 (TCP 로 몰래 주고받는 것이 아님을 확인하는 항목)

- 검사 스크립트를 짤 때 주의할 점
  - 서버 쪽 프로그램을 `ssh` 안에서 `&` 로 뒤에 띄우면 뜨지 않음. ssh 를 두 개 띄워 하나를 서버로 써야 함 (실측)
  - 출력이 파이프로 갈 때는 `stdbuf -o0` 를 앞에 붙여야 `timeout` 으로 끊어도 내용이 남음 (실측)
  - `ibv_rc_pingpong` 은 반드시 `-n 10` 처럼 횟수를 줄여서 씀. 기본 1000회는 이 PC 에서 끝나지 않음 (실측)
  - `sudo stdbuf ...` 는 듣지 않음(`sudo` 가 `LD_PRELOAD` 를 지움). tcpdump 는 그래도 출력이 나옴 (실측)

## 고장 연습 후보

| 고장 | 내는 방법 | 어떤 검사 항목이 잡아야 하나 | 확인 여부 |
|------|-----------|---------------------------|-----------|
| RDMA 장치를 지움 | `sudo rdma link delete rxe0` | 2번(장치 없음), 4번(통신 실패) | 확인 못 함 |
| 커널 모듈을 내림 | `sudo rdma link delete rxe0 && sudo modprobe -r rdma_rxe` | 2번, 4번 | 확인 못 함 |
| 엉뚱한 랜카드에 장치를 붙임 | `rdma link add rxe0 type rxe netdev enp0s3`(NAT 쪽) | 2번의 `netdev` 가 다름, 4번 실패 | 확인 못 함 |
| 내부망 선을 뽑음 | `VBoxManage.exe controlvm rdma2 setlinkstate2 off` | 1번은 통과하나 4번과 5번 실패 | 확인 못 함 |
| GID 번호를 틀리게 씀 | 시험 명령에서 `-g 1` 대신 `-g 0` | 통신은 되나 5번에서 IPv6 주소로 오감 | 확인 못 함 |
| 되돌리기 | `./vm-down.sh --delete && ./vm-up.sh`, 또는 VM 안에서 `sudo systemctl restart lab5-rxe` | | 되돌리기는 실측함 |

- 위 고장 중 어느 것도 실제로 내 보지는 않았음. 랩니가 `fault-demo.sh` 를 만들 때 확인이 필요함

## 막힌 점과 해결

1. **WSL 커널에 `rdma_rxe` 가 없음** → VirtualBox VM 방식으로 바꿈(사용자 결정). VM 안 Ubuntu 커널에는 있음.  
   단 기본 커널 꾸러미에는 없고 `linux-modules-extra-$(uname -r)` 에 들어 있어 cloud-init 에서 따로 받음
2. **이미지를 들여온 뒤 처음 켤 때 initramfs 에서 멈춤**  
   부팅 메시지가 `Begin: Loading essential drivers ...` 에서 멈추고 더 나아가지 않음. rdma1 과 rdma2 양쪽에서 같음.  
   전원을 껐다 켜면 정상으로 부팅됨. `vm-up.sh` 가 210초 안에 SSH 가 안 열리면 전원을 껐다 켜도록 넣음(최대 3번).  
   원인은 찾지 못함
3. **VirtualBox 화면이 멈춘 것처럼 보임**  
   클라우드 이미지가 콘솔을 직렬 포트(ttyS0)로 넘기기 때문이며 고장이 아님.  
   `vm-up.sh` 가 직렬 포트를 `.cache/vms/<이름>/serial.log` 로 받게 해 두었으므로 그 파일로 진행 상황을 봄
4. **WSL 에서 VM 으로 SSH 가 안 붙음**  
   VM 은 Windows 쪽 VirtualBox 가 띄우므로 WSL 의 `127.0.0.1` 로는 못 감.  
   WSL 의 기본 게이트웨이(= Windows 호스트, 이 PC 는 172.26.240.1)로 붙어야 함. `_common.sh` 의 `WIN_HOST` 가 이것을 구함
5. **ssh 안에서 서버 프로그램을 `&` 로 띄우면 안 뜸**  
   `nohup ... &` 를 써도 뜨지 않음. WSL 쪽에서 ssh 를 두 개 띄워 하나를 서버로 쓰는 방식으로 해결함
6. **`ibv_rc_pingpong` 기본값(1000회)이 끝나지 않음**  
   한 번은 VM 커널이 `soft lockup` 으로 멈췄고(`watchdog: BUG: soft lockup - CPU#1 stuck for 130s!`),  
   한 번은 아무 출력 없이 멎었음. `-n 10` 처럼 횟수를 줄이면 정상으로 끝남.  
   `ibv_rc_pingpong` 이 완료를 바쁜 대기로 기다리는데, CPU 2개짜리 VM 에서 Soft-RoCE 커널 작업과 다투는 것으로 보임(추정)
7. **`timeout` 으로 끊으면 출력이 사라짐**  
   출력이 파이프로 갈 때 버퍼에 갇히기 때문임. `stdbuf -o0 -e0` 을 앞에 붙여 해결함

## 확인하지 못한 것

- **강의장 PC 에서의 동작**. 여기 적은 모든 값은 강사 PC(i9-14900HX, 메모리 32GB) 실측이며, 강의장 PC 는 따로 확인해야 함
- **`ibv_rc_pingpong` 기본값이 멈추는 정확한 원인**. CPU 개수를 늘리거나 메모리를 줄여 보는 시험은 하지 않았음
- **처음 켤 때 initramfs 에서 멈추는 원인**. VirtualBox 로그에 오류 줄은 없었음
- **위 「고장 연습 후보」 표의 고장을 실제로 내 본 결과**
- **VM 을 세 대 이상 띄웠을 때의 동작**. 두 대까지만 확인함
- **수업 중 WSL 과 Docker Desktop 을 함께 쓸 때의 영향**.  
  이번 작업 중에도 lab2 컨테이너 6개와 다른 프로젝트 컨테이너 3개가 함께 돌았고 문제는 없었으나,  
  수강생 전원이 동시에 띄우는 상황은 확인하지 못함
- **`rdma link` 의 `siw` 방식**(iWARP 흉내). `rdma_rxe` 만 확인함

## 실행 속도에 대한 솔직한 메모

- 이 PC 는 WSL2 와 Docker Desktop 이 Windows 의 하드웨어 가상화를 이미 잡고 있어,
  VirtualBox 가 전용 가속(VT-x)을 못 쓰고 Windows 의 가상화 계층을 빌려 쓰는 느린 방식으로 돎
  (VirtualBox 로그: `HM: HMR3Init: Attempting fall back to NEM: VT-x is not available`)
- 그래서 VM 안 명령 반응이 또렷하게 느리고, 처음 만들 때 시간이 오래 걸림
- 수업에 쓸 때는 **쉬는 시간이나 수업 시작 전에 `./vm-up.sh` 를 미리 돌려 두고**,
  수업 중에는 `./vm-ssh.sh` 로 들어가 명령만 치는 흐름을 권함
- VM 을 끄고 다시 켜는 것은 1분 안쪽이므로, 지우지 말고 꺼 두었다가 다음 시간에 다시 켜는 쪽이 나음
