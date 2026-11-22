# lab3 VxLAN 터널 손으로 만들기 (넷니 작업 기록)

## 목표
- lab2와 같은 leaf-spine + BGP unnumbered를 바탕(언더레이)으로 둠
- 서로 다른 leaf에 붙은 h1, h2를 같은 서브넷(10.10.10.0/24)으로 묶음
- 묶는 방법은 VxLAN(VNI 100). 상대 leaf의 VTEP 주소를 사람이 손으로 적음
- 다음 실습(lab4)에서 이 "손으로 적는 부분"을 EVPN이 대신 해 주는 것과 비교함

## 파일
| 파일 | 내용 |
|------|------|
| `lab3.clab.yml` | 토폴로지. leaf의 `exec`가 `cfg/vxlan-static.sh`를 실행함 |
| `cfg/spine1.conf`, `cfg/spine2.conf` | lab2와 같음(언더레이 BGP) |
| `cfg/leaf1.conf`, `cfg/leaf2.conf` | lab2에서 서버 대역 `network` 줄과 eth3 주소를 뺌. 루프백만 알림 |
| `cfg/vxlan-static.sh` | br100, vxlan100을 만들고 상대 VTEP을 fdb에 손으로 넣음. 인자: 내 VTEP, 상대 VTEP |
| `cfg/daemons`, `cfg/vtysh.conf` | lab2와 같음 |
| `clab.sh` | lab2 것 복사(containerlab을 컨테이너로 실행) |

## 구성도
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

  오버레이(VNI 100):
  h1 --eth3-- [leaf1 br100] vxlan100 ==(UDP 4789, 10.0.0.11 <-> 10.0.0.12)== vxlan100 [leaf2 br100] --eth3-- h2
```

## 연결과 주소표
| 장비 | 인터페이스 | 상대 | 주소 |
|------|-----------|------|------|
| spine1 | lo | | 10.0.0.1/32 |
| spine1 | eth1, eth2 | leaf1 eth1, leaf2 eth1 | IP 없음(BGP unnumbered, IPv6 링크 로컬) |
| spine2 | lo | | 10.0.0.2/32 |
| spine2 | eth1, eth2 | leaf1 eth2, leaf2 eth2 | IP 없음(BGP unnumbered) |
| leaf1 | lo | | 10.0.0.11/32 (VTEP) |
| leaf1 | eth1, eth2 | spine1 eth1, spine2 eth1 | IP 없음(BGP unnumbered) |
| leaf1 | eth3 | h1 eth1 | IP 없음, br100 포트 |
| leaf1 | vxlan100 | | VNI 100, local 10.0.0.11, dstport 4789, br100 포트 |
| leaf2 | lo | | 10.0.0.12/32 (VTEP) |
| leaf2 | eth1, eth2 | spine1 eth2, spine2 eth2 | IP 없음(BGP unnumbered) |
| leaf2 | eth3 | h2 eth1 | IP 없음, br100 포트 |
| leaf2 | vxlan100 | | VNI 100, local 10.0.0.12, dstport 4789, br100 포트 |
| h1 | eth1 | leaf1 eth3 | 10.10.10.11/24, MTU 1500 |
| h2 | eth1 | leaf2 eth3 | 10.10.10.12/24, MTU 1500 |

- BGP AS: spine 65000(두 대 같음), leaf1 65101, leaf2 65102
- 관리 네트워크: `dcnet-mgmt`(172.30.30.0/24), 컨테이너 이름 `clab-lab3-*`

## 띄우기와 내리기
```bash
cd /mnt/c/Users/hiond/class/aidc/labs/lab3-vxlan-static
./clab.sh deploy -t lab3.clab.yml
./clab.sh destroy -t lab3.clab.yml --cleanup
```

## 확인 명령과 정상일 때 출력 (2026-11-23 강사 PC 실측)
> MAC 주소와 fe80 주소는 띄울 때마다 바뀜. 아래는 실제 출력에서 핵심 줄만 옮김(BGP 요약의 Desc 열은 생략).

1. 언더레이 BGP 이웃: `docker exec clab-lab3-leaf1 vtysh -c "show bgp summary"`
   ```text
   spine1(eth1)    4      65000        14        15        4    0    0 00:00:27            2        4
   spine2(eth2)    4      65000        14        15        4    0    0 00:00:26            2        4
   ```
2. 상대 VTEP 루프백을 BGP로 배웠고 두 spine을 모두 씀:  
   `docker exec clab-lab3-leaf1 vtysh -c "show ip route 10.0.0.12"`
   ```text
   Known via "bgp", distance 20, metric 0, best
   * fe80::a8c1:abff:fe01:64b5, via eth2, weight 1
   * fe80::a8c1:abff:feb6:582, via eth1, weight 1
   ```
3. 서버끼리 통신: `docker exec clab-lab3-h1 ping -c 3 10.10.10.12`
   ```text
   3 packets transmitted, 3 received, 0% packet loss
   ```
4. 손으로 넣은 상대 VTEP이 fdb에 있음: `docker exec clab-lab3-leaf1 bridge fdb show dev vxlan100`
   ```text
   aa:c1:ab:f9:4b:5d dst 10.0.0.12 self
   00:00:00:00:00:00 dst 10.0.0.12 self permanent
   ```
   - `00:00:00:00:00:00 ... permanent` 줄이 `vxlan-static.sh`가 손으로 넣은 줄
   - MAC이 적힌 `dst 10.0.0.12 self` 줄은 터널로 들어온 패킷을 보고 커널이 스스로 배운 줄(learning 켜짐)
5. VxLAN 인터페이스 값: `docker exec clab-lab3-leaf1 ip -d link show vxlan100`
   ```text
   vxlan id 100 local 10.0.0.11 srcport 0 0 dstport 4789
   ```
6. 언더레이에서 캡슐화 확인(leaf1의 네트워크 공간에 multitool을 붙여 tcpdump):
   ```bash
   docker run --rm --network container:clab-lab3-leaf1 ghcr.io/hellt/network-multitool:latest \
     timeout 8 tcpdump -nni any -c 4 udp port 4789
   # 다른 창에서: docker exec clab-lab3-h1 ping -c 3 10.10.10.12
   ```
   ```text
   IP 10.0.0.11.36837 > 10.0.0.12.4789: VXLAN, flags [I] (0x08), vni 100
   IP 10.10.10.11 > 10.10.10.12: ICMP echo request, id 18734, seq 1, length 64
   ```
   - 바깥 머리는 VTEP 주소(10.0.0.11 -> 10.0.0.12, UDP 4789), 안쪽은 서버 주소(10.10.10.x)
   - multitool 시작 시 나오는 `Cannot set device feature settings`, `nginx/html is not mounted` 줄은 무시해도 됨
7. EVPN을 쓰지 않음: `docker exec clab-lab3-leaf1 vtysh -c "show evpn vni"` 출력이 비어 있음

## 다시 띄우기 확인
- `destroy --cleanup` 뒤 컨테이너 0개, `clab-lab3` 폴더 지워짐, `dcnet-mgmt`와 lab2는 그대로 남음
- 다시 `deploy` 뒤 위 1 ~ 6번이 같은 결과(ping 3/3, fdb 손 VTEP 줄, tcpdump vni 100)
- lab2, lab4와 동시에 떠 있는 상태(컨테이너 18개)에서도 lab3 ping 정상

## 랩니 검사 항목 제안
1. leaf마다 ipv4 BGP 이웃 2개 Established (`show bgp summary json`, lab2 check.sh와 같은 방식)
2. 상대 VTEP 루프백 /32가 `bgp`로 들어오고 활성 다음 홉 2개  
   (`show ip route 10.0.0.12/32 json`, lab2 `check_route`와 같은 방식)
3. vxlan100 값이 맞음: `ip -j -d link show vxlan100 | jq '.[0].linkinfo.info_data'`의  
   `id`=100, `local`=자기 루프백, `port`=4789 (필드 이름 실측함)
4. fdb에 `00:00:00:00:00:00 dst <상대 VTEP> self permanent` 줄이 있음. VTEP 주소를 틀리게 적는 실수가 가장 흔함
5. h1 -> h2 ping 성공. 가능하면 ping 중 tcpdump로 `vni 100` 줄이 보이는지까지 확인(시간이 몇 초 더 듦)

## 막힌 점과 해결
- 막힌 점 없이 첫 시도에 통신됨. 아래는 미리 막아 둔 부분
- MTU: containerlab이 만드는 선은 MTU 9500이고, vxlan100은 기본 1500임.  
  h1, h2와 leaf eth3을 1500으로 맞춰 브리지 안에서 크기가 어긋나지 않게 함.  
  언더레이가 9500이라 VxLAN 머리 50바이트가 붙어도 안쪽 1500 패킷이 잘리지 않음  
  (lab4에서 `ping -M do -s 1472` 성공으로 확인)
- leaf의 서버 대역 `network` 줄(lab2의 192.168.x)을 뺌. 이제 h1, h2는 2계층으로 이어지므로 BGP는 루프백만 알림
- `exec`는 FRR이 루프백 주소를 넣기 전에 돌 수 있음. 커널은 아직 없는 주소를 `local`로 줘도 vxlan을 만들어 주며,  
  실제 통신에도 문제없었음

## 확인하지 못한 것
- 강의장 PC(강사 PC 아님)에서의 동작
- leaf가 3대 이상일 때(상대 VTEP마다 fdb 줄을 하나씩 더 적어야 함)
