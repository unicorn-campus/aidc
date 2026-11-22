# lab2 leaf-spine 구조를 BGP로 잇기

## 이 실습에서 배우는 것
- lab1은 스위치 2대였지만, 여기서는 데이터센터에서 쓰는 leaf-spine 구조(스위치 4대와 서버 2대)를 만듦  
- 길 찾기 방식이 OSPF에서 BGP로 바뀜. 스위치 사이 선에 IP 주소를 따로 붙이지 않고 인터페이스 이름만으로 이웃을 맺음  
- leaf1에서 leaf2 쪽 서버로 가는 길이 spine 2대를 거쳐 2개가 생기고, 트래픽이 두 길로 나뉘어 감

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
            | lo 10.0.0.11     |            | lo 10.0.0.12     |
            +-------eth3-------+            +-------eth3-------+
                     |                               |
              h1 192.168.1.10/24              h2 192.168.2.10/24
```

- 선 연결: leaf1 eth1 - spine1 eth1, leaf1 eth2 - spine2 eth1, leaf2 eth1 - spine1 eth2, leaf2 eth2 - spine2 eth2  
- leaf마다 spine 2대에 모두 연결되어 있고, spine끼리와 leaf끼리는 선이 없음

| 장비 | 인터페이스 | 주소 | 비고 |
|------|-----------|------|------|
| spine1 | lo | 10.0.0.1/32 | AS 65000 |
| spine2 | lo | 10.0.0.2/32 | AS 65000 |
| leaf1 | lo | 10.0.0.11/32 | AS 65101 |
| leaf1 | eth3 | 192.168.1.1/24 | h1이 넘기는 곳(게이트웨이) |
| leaf2 | lo | 10.0.0.12/32 | AS 65102 |
| leaf2 | eth3 | 192.168.2.1/24 | h2가 넘기는 곳(게이트웨이) |
| h1 | eth1 | 192.168.1.10/24 | 서버 역할 |
| h2 | eth1 | 192.168.2.10/24 | 서버 역할 |

- 스위치 사이 선(eth1, eth2)에는 IP 주소가 없음(BGP unnumbered)  
- 컨테이너 이름은 `clab-lab2-spine1`, `clab-lab2-spine2`, `clab-lab2-leaf1`, `clab-lab2-leaf2`, `clab-lab2-h1`, `clab-lab2-h2`임

## 준비물
- Docker Desktop이 켜져 있어야 함  
- Windows 터미널(또는 PowerShell)을 열고 `wsl`을 입력해 WSL을 엶  
- 실습 폴더로 이동함. 아래 `<사용자>`는 내 Windows 사용자 이름으로 바꿈  
  ```bash
  cd /mnt/c/Users/<사용자>/class/aidc/labs/lab2-leaf-spine-bgp
  ```
- 앞 실습(lab1 등)이 떠 있으면 그 폴더에서 먼저 끔

## 따라 하기
1. 실습 환경을 띄움  
   ```bash
   ./reset.sh
   ```
   이렇게 나오면 성공: `다시 띄웠습니다...` 뒤 20초 정도 기다리면 검사 결과가 나오고 마지막 줄이 `결과: 모두 통과`임  
   뜻: `reset.sh`는 처음 상태로 지우고 다시 띄운 뒤 검사(`check.sh`)까지 한 번에 돌려 줌

2. leaf1의 BGP 이웃을 확인함  
   ```bash
   docker exec clab-lab2-leaf1 vtysh -c "show bgp summary"
   ```
   이렇게 나오면 성공: 이웃이 2줄(`spine1(eth1)`, `spine2(eth2)`)이고 `State/PfxRcd` 칸에 숫자가 보임(시간 값은 바뀔 수 있음)  
   ```text
   Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt
   spine1(eth1)    4      65000       794       795        6    0    0 00:39:25            3        6
   spine2(eth2)    4      65000       794       795        6    0    0 00:39:24            3        6
   ```
   뜻: leaf1이 spine1, spine2와 BGP 이웃을 맺음. `State/PfxRcd` 칸에 숫자가 보이면 정상이고, `Active`나 `Idle`이 보이면 아직 못 맺은 것임

3. leaf1이 h2 쪽 대역을 어떻게 배웠는지 확인함  
   ```bash
   docker exec clab-lab2-leaf1 vtysh -c "show ip route 192.168.2.0/24"
   ```
   이렇게 나오면 성공: `Known via "bgp"`가 보이고, 다음 길이 `via eth1`과 `via eth2` 두 줄임(`fe80::` 주소는 바뀔 수 있음)  
   ```text
   Routing entry for 192.168.2.0/24
     Known via "bgp", distance 20, metric 0, best
     * fe80::a8c1:abff:fe37:5937, via eth1, weight 1
     * fe80::a8c1:abff:fe60:bb05, via eth2, weight 1
   ```
   뜻: 길이 BGP로 들어왔고, spine1(eth1)과 spine2(eth2) 두 길을 모두 씀(ECMP)

4. 서버끼리 통신해 봄  
   ```bash
   docker exec clab-lab2-h1 ping -c 3 192.168.2.10
   ```
   이렇게 나오면 성공: `3 packets transmitted, 3 received, 0% packet loss`  
   뜻: leaf1 쪽 서버 h1에서 leaf2 쪽 서버 h2까지 패킷이 갔다 돌아옴

5. 중간에 어떤 장비를 거치는지 봄  
   ```bash
   docker exec clab-lab2-h1 traceroute -n 192.168.2.10
   ```
   이렇게 나오면 성공: 4줄이 나오고, 1번째가 `192.168.1.1`(leaf1), 2번째가 spine(`10.0.0.1` 또는 `10.0.0.2`), 3번째가 `10.0.0.12`(leaf2)임  
   ```text
    1  192.168.1.1  ...
    2  10.0.0.2  ...
    3  10.0.0.12  ...
    4  192.168.2.10  ...
   ```
   뜻: h1 -> leaf1 -> spine -> leaf2 -> h2 순서로 지나감. 2번째 줄이 spine1이냐 spine2냐는 실행할 때마다 다를 수 있음

6. 검사를 돌림  
   ```bash
   ./check.sh
   ```
   이렇게 나오면 성공: 항목 5개가 모두 `[통과]`이고 마지막 줄이 `결과: 모두 통과`임  
   ```text
   1) leaf마다 spine 2대와 BGP 이웃이 맺어졌는가
     [통과] leaf1: 이웃 2개 정상
     [통과] leaf2: 이웃 2개 정상
   2) 상대편 서버 대역을 BGP로 배웠고, 두 spine을 모두 쓰는가(ECMP)
     [통과] leaf1: 192.168.2.0/24 를 BGP로 배웠고 길 2개 사용
     [통과] leaf2: 192.168.1.0/24 를 BGP로 배웠고 길 2개 사용
   3) 서버 h1에서 h2로 통신되는가
     [통과] h1 -> h2 통신 정상
   결과: 모두 통과
   ```
   뜻: ping이 된다는 것만이 아니라 "BGP로 배운 길이고 길이 2개인가"까지 확인함

7. 실습 환경을 끔  
   ```bash
   ./clab.sh destroy -t lab2.clab.yml --cleanup
   ```
   이렇게 나오면 성공: `Removed container` 줄이 6개 보임(미확인: 이 안내서 작성 중에는 lab2를 계속 띄워 두어 끄는 출력은 보지 못함)  
   뜻: 6개 컨테이너를 모두 지움

## 고장 연습
`./fault-demo.sh`는 고장을 하나씩 내고 `check.sh`를 돌린 뒤 바로 원래대로 되돌림. 마지막에 `복구 확인`으로 다시 검사함  
(아래 표는 2026-11-23 강사 PC에서 `fault-demo.sh`를 실제로 돌린 결과임)

| 번호 | 일부러 내는 고장 | 실패로 잡힌 검사 | ping |
|------|------------------|------------------|------|
| 1 | leaf1과 spine1 사이 선(eth1)을 끊음 | 1번(이웃 1개뿐), 2번(길 1개뿐) | 됨 |
| 2 | leaf2가 서버 대역(192.168.2.0/24)을 BGP로 알리지 않음 | 2번(leaf1에 길이 없음), 3번(통신 안 됨) | 안 됨 |
| 3 | BGP 대신 손으로 static 경로를 넣어 통신만 되게 함(편법) | 2번(BGP가 아니라 static이라고 알려 줌) | 됨 |

- 1번과 3번은 ping이 되는데도 검사는 실패함. ping만 보면 고장을 놓친다는 것이 이 연습의 핵심임

## 막혔을 때
1. Docker Desktop이 켜져 있는지, `docker ps`에 `clab-lab2-`로 시작하는 컨테이너 6개가 있는지 확인함  
2. `./check.sh`에서 1번이 실패하면 띄운 지 20초가 안 지났을 수 있으므로 잠시 기다린 뒤 다시 돌림  
3. 이웃이 안 맺어지면 `docker exec -it clab-lab2-leaf1 vtysh`로 들어가 `show bgp summary`를 확인함(나올 때는 `exit`)  
4. 실패 항목 아래에 나오는 `힌트:` 줄을 읽고 그대로 따라 해 봄  
5. 두 번 시도해도 안 되면 `./reset.sh`로 처음 상태로 되돌림

## 용어 풀이
| 용어 | 쉬운 말 |
|------|---------|
| leaf-spine | 서버 쪽 스위치(leaf)와 그 위의 스위치(spine)를 그물처럼 잇는 구조. 어느 서버끼리든 spine 한 번만 거치면 닿음 |
| leaf | 서버가 직접 꽂히는 스위치 |
| spine | leaf들을 서로 이어 주는 스위치. 서버는 꽂지 않음 |
| BGP | 서로 다른 번호(AS)를 가진 장비끼리 길을 주고받는 방식. 데이터센터에서는 장비마다 번호를 따로 줌 |
| AS 번호 | BGP에서 장비(또는 조직)를 구분하는 번호. 이 실습은 spine 65000, leaf1 65101, leaf2 65102 |
| BGP unnumbered | 선에 IP를 붙이지 않고 인터페이스 이름(eth1)만으로 BGP 이웃을 맺는 방식 |
| 이웃(neighbor) | 길을 주고받기로 한 옆 장비 |
| ECMP | 길이 같은 값으로 여러 개일 때 트래픽을 그 길들로 나눠 보내는 것 |
| 게이트웨이 | 서버가 다른 대역으로 보낼 때 일단 넘기는 곳. 이 실습의 서버는 192.168.0.0/16 대역을 자기 leaf에 넘김 |
| ping | 상대에게 신호를 보내고 답이 오는지 보는 명령 |
| traceroute | 목적지까지 어떤 장비를 차례로 거치는지 보여 주는 명령 |
