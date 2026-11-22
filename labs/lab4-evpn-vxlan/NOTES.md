# lab4 EVPN으로 VxLAN 자동화 (넷니 작업 기록)

## 목표
- lab3과 같은 구성(leaf-spine, VNI 100, h1과 h2 같은 서브넷)에서 손으로 적던 상대 VTEP을 지움
- BGP `l2vpn evpn` 주소 계열을 켜고 `advertise-all-vni`로 각 leaf가 자기 VNI를 알리게 함
- leaf의 FRR(zebra)이 받은 EVPN 경로로 터널 행선지(fdb)를 스스로 채우는 것을 확인함

## lab3과 달라진 점
| 구분 | lab3 (손으로) | lab4 (EVPN) |
|------|---------------|-------------|
| 상대 VTEP | `bridge fdb append 00:00:00:00:00:00 ... dst <상대>` 손으로 적음 | 적지 않음. 타입 3 경로로 배움 |
| 상대 서버 MAC | 터널로 들어온 패킷을 보고 커널이 배움(learning) | 타입 2 경로로 배움. vxlan100은 `nolearning` |
| leaf BGP | `ipv4 unicast`만 | `ipv4 unicast` + `l2vpn evpn`(`neighbor fabric activate`, `advertise-all-vni`) |
| spine BGP | `ipv4 unicast`만 | `l2vpn evpn`에 `neighbor fabric activate`만 더함(VNI 없음, 경로 전달만) |
| 설정 스크립트 | `cfg/vxlan-static.sh <내 VTEP> <상대 VTEP>` | `cfg/vxlan-evpn.sh <내 VTEP>` |

## 파일
| 파일 | 내용 |
|------|------|
| `lab4.clab.yml` | 토폴로지. leaf의 `exec`가 `cfg/vxlan-evpn.sh`를 실행함 |
| `cfg/spine1.conf`, `cfg/spine2.conf` | lab2 설정 + `address-family l2vpn evpn` / `neighbor fabric activate` |
| `cfg/leaf1.conf`, `cfg/leaf2.conf` | lab3 설정 + `l2vpn evpn` 주소 계열(`neighbor fabric activate`, `advertise-all-vni`) |
| `cfg/vxlan-evpn.sh` | br100, vxlan100(nolearning)을 만들고 eth3을 꽂음. fdb 줄 없음. 인자: 내 VTEP |
| `cfg/daemons`, `cfg/vtysh.conf` | lab2와 같음(zebra, bgpd만 켬) |
| `clab.sh` | lab2 것 복사 |

## 구성도
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

  BGP(같은 이웃 관계 위에 두 주소 계열):
    ipv4 unicast : 루프백 10.0.0.11, 10.0.0.12 를 서로 알림(터널 바깥 길)
    l2vpn evpn   : 타입 3 "나는 VNI 100의 VTEP", 타입 2 "VNI 100에 이 MAC이 내 뒤에 있음"
```

## 연결과 주소표
- lab3과 같음(아래 요약). 자세한 표는 `../lab3-vxlan-static/NOTES.md` 참조

| 장비 | 주소 | 비고 |
|------|------|------|
| spine1 | lo 10.0.0.1/32 | AS 65000 |
| spine2 | lo 10.0.0.2/32 | AS 65000 |
| leaf1 | lo 10.0.0.11/32 (VTEP) | AS 65101, eth3과 vxlan100이 br100 포트 |
| leaf2 | lo 10.0.0.12/32 (VTEP) | AS 65102, eth3과 vxlan100이 br100 포트 |
| h1 | eth1 10.10.10.11/24 | leaf1 eth3에 연결, MTU 1500 |
| h2 | eth1 10.10.10.12/24 | leaf2 eth3에 연결, MTU 1500 |

- 스위치 사이 선은 IP 없음(BGP unnumbered). 관리 네트워크 `dcnet-mgmt`, 컨테이너 이름 `clab-lab4-*`

## 띄우기와 내리기
```bash
cd /mnt/c/Users/hiond/class/aidc/labs/lab4-evpn-vxlan
./clab.sh deploy -t lab4.clab.yml
./clab.sh destroy -t lab4.clab.yml --cleanup
```

## 확인 명령과 정상일 때 출력 (2026-11-23 강사 PC 실측, 다시 띄운 뒤 출력)
> MAC 주소는 띄울 때마다 바뀜. 서버 MAC은 서버가 한 번이라도 패킷을 보내야 leaf가 배우므로 ping을 먼저 함(BGP 요약의 Desc 열은 생략).

1. 서버끼리 통신: `docker exec clab-lab4-h1 ping -c 3 10.10.10.12`
   ```text
   3 packets transmitted, 3 received, 0% packet loss
   ```
2. EVPN 이웃: `docker exec clab-lab4-leaf1 vtysh -c "show bgp l2vpn evpn summary"`
   ```text
   spine1(eth1)    4      65000        20        21        4    0    0 00:00:28            2        4
   spine2(eth2)    4      65000        20        22        4    0    0 00:00:29            2        4
   ```
3. EVPN 경로: `docker exec clab-lab4-leaf1 vtysh -c "show bgp l2vpn evpn route"`
   ```text
   Route Distinguisher: 10.0.0.11:2
    *>  [2]:[0]:[48]:[aa:c1:ab:b9:18:5f]          <- 타입 2, 내 쪽 h1 MAC
    *>  [3]:[0]:[32]:[10.0.0.11]                  <- 타입 3, 나(VTEP 10.0.0.11)
   Route Distinguisher: 10.0.0.12:2
    *>  [2]:[0]:[48]:[aa:c1:ab:83:78:72]          <- 타입 2, leaf2 뒤 h2 MAC
                        10.0.0.12(spine1)
                                                           0 65000 65102 i
                        RT:65102:100 ET:8
    *=  [2]:[0]:[48]:[aa:c1:ab:83:78:72]          <- 같은 경로를 spine2로도 받음
    *>  [3]:[0]:[32]:[10.0.0.12]                  <- 타입 3, leaf2(VTEP 10.0.0.12)
    *=  [3]:[0]:[32]:[10.0.0.12]
   Displayed 4 prefixes (6 paths)
   ```
   - 화살표 뒤 설명은 이해를 돕기 위해 덧붙인 것이며 실제 출력에는 없음
   - 다음 홉이 spine이 아니라 `10.0.0.12`(leaf2 VTEP)로 그대로 남음. `(spine1)`은 경로를 건네준 이웃 이름
   - 타입별로 보기: `show bgp l2vpn evpn route type macip`(타입 2), `... type multicast`(타입 3)
4. VNI 상태: `docker exec clab-lab4-leaf1 vtysh -c "show evpn vni"`, `show evpn vni 100`
   ```text
   VNI        Type VxLAN IF              # MACs   # ARPs   # Remote VTEPs  Tenant VRF
   100        L2   vxlan100              2        0        1               default
    Local VTEP IP: 10.0.0.11
    Remote VTEPs for this VNI:
     10.0.0.12 flood: HER
   ```
   - `flood: HER`는 브로드캐스트를 상대 VTEP마다 하나씩 복사해 보내는 방식(헤드엔드 복제). 타입 3 경로로 배운 결과
5. MAC 표: `docker exec clab-lab4-leaf1 vtysh -c "show evpn mac vni 100"`
   ```text
   aa:c1:ab:b9:18:5f local        eth3
   aa:c1:ab:83:78:72 remote       10.0.0.12
   ```
6. 커널 fdb(zebra가 넣은 줄): `docker exec clab-lab4-leaf1 bridge fdb show dev vxlan100`
   ```text
   aa:c1:ab:83:78:72 dst 10.0.0.12 self extern_learn
   00:00:00:00:00:00 dst 10.0.0.12 self permanent
   ```
   - `extern_learn`은 커널이 아니라 바깥 프로그램(FRR zebra)이 넣었다는 표시. lab3에는 이 표시가 없음
   - `00:00:00:00:00:00` 줄은 lab3과 모양이 같지만, 손으로 넣지 않았고 타입 3 경로를 받아 zebra가 넣은 줄
7. 캡슐화 확인(lab3과 같은 방법):
   ```text
   IP 10.0.0.11.36837 > 10.0.0.12.4789: VXLAN, flags [I] (0x08), vni 100
   IP 10.10.10.11 > 10.10.10.12: ICMP echo request, id 3598, seq 1, length 64
   ```
8. 큰 패킷: `docker exec clab-lab4-h1 ping -c 2 -M do -s 1472 10.10.10.12` 성공(안쪽 1500바이트가 쪼개지지 않고 지나감)

## 다시 띄우기 확인
- `destroy --cleanup` 뒤 컨테이너 0개, `clab-lab4` 폴더 지워짐, `dcnet-mgmt`와 lab2는 그대로 남음
- 다시 `deploy` 뒤 위 1 ~ 7번이 같은 결과(ping 3/3, 타입 2 경로 2개, 타입 3 경로 2개, Remote VTEP 10.0.0.12)
- leaf2에서도 반대로 확인: Remote VTEP 10.0.0.11, `aa:c1:ab:b9:18:5f remote 10.0.0.11`

## 랩니 검사 항목 제안
> JSON 필드는 아래 표시한 것만 실측함. 나머지는 검사 작성 때 확인 필요.

1. h1 -> h2 ping을 먼저 실행하고 성공 확인(서버 MAC을 leaf가 배우게 하는 역할도 겸함)
2. leaf마다 `l2vpn evpn` 이웃 2개 Established (`show bgp l2vpn evpn summary json`, 필드 이름은 미확인)
3. 타입 3: `show bgp l2vpn evpn route type multicast json`에 상대 VTEP 키 `[3]:[0]:[32]:[10.0.0.12]`가 있음  
   (키는 RD 아래 한 단계 안쪽에 있음. 실측함)
4. 원격 VTEP: `show evpn vni 100 json`의 `numRemoteVteps`=1, `vtepIp`=자기 루프백 (실측함).  
   "손으로 넣은 것이 아님"은 커널 fdb의 `00:00:00:00:00:00 dst` 목록과 이 원격 VTEP 목록이 같은지로 봄
5. 타입 2: `show evpn mac vni 100 json`의 `.macs[]` 중 `type`="remote", `remoteVtep`=상대 VTEP인 항목이 1개 이상  
   (실측함). 또 `ip -j -d link show vxlan100`의 `learning`=false(nolearning)인지 확인

- 고장 연습 후보: leaf 한 대에서 `advertise-all-vni`를 지우면 상대 leaf의 Remote VTEP과 remote MAC이 사라지고 통신이 끊길 것으로  
  예상(확인 못 함)

## 막힌 점과 해결
- 막힌 점 없이 첫 시도에 통신됨. 미리 걱정했다가 실측으로 확인한 점은 아래와 같음
- 경로 표시(RT)가 leaf마다 다름(leaf1 `65101:100`, leaf2 `65102:100`). FRR이 자동으로 만든 RT라 AS 번호가 다른데도  
  상대 경로를 정상으로 가져옴(`show evpn mac`에 remote MAC이 보임). 그래서 `route-target`을 손으로 적지 않음
- eBGP인데도 spine이 EVPN 경로의 다음 홉을 자기로 바꾸지 않고 leaf VTEP 주소(10.0.0.12)를 그대로 넘김.  
  spine에 따로 설정한 것 없음
- 타입 2 경로에 MAC만 실리고 IP는 없음(`# ARPs 0`, 경로 모양 `[2]:[0]:[48]:[MAC]`).  
  이 실습은 2계층만 잇고 br100에 IP(SVI)가 없어 leaf가 서버 IP를 배울 길이 없기 때문임.  
  MAC과 IP를 함께 싣는 모습은 SVI와 ARP 억제(`advertise-svi-ip`, `neigh_suppress`)를 다루는 다음 단계 몫
- MTU는 lab3과 같은 방식으로 맞춤(서버와 eth3을 1500, 언더레이 9500)

## 확인하지 못한 것
- 강의장 PC(강사 PC 아님)에서의 동작
- 서버가 오래 조용하면 브리지 MAC 나이 제한(300초) 뒤 로컬 MAC이 지워지고 타입 2 경로가 빠질 것으로 예상하나  
  기다려 확인하지 않음. 검사에서 ping을 먼저 하라고 한 이유
- `show bgp l2vpn evpn summary json`의 필드 이름
- `advertise-all-vni`를 지웠을 때의 고장 모습
