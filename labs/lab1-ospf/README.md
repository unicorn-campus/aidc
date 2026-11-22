# lab1 스위치 2대를 OSPF로 잇기

## 이 실습에서 배우는 것
- 스위치 2대를 선 하나로 잇고, 서로의 주소를 OSPF로 저절로 알게 만듦  
- 주소를 사람이 하나씩 적는 방식(static 경로)과 달리, 스위치가 자기 주소를 이웃에게 알려 주고 이웃의 주소를 배움  
- 첫 실습이라 비교할 앞 실습은 없음. 이후 lab2 ~ lab4가 이 실습 위에 쌓임

## 구성도와 주소표
```text
   +----------------------+                    +----------------------+
   | sw1                  |                    | sw2                  |
   | lo   10.0.0.1/32     |                    | lo   10.0.0.2/32     |
   |                      |                    |                      |
   | eth1 192.168.12.1/30 |-------- 선 --------| eth1 192.168.12.2/30 |
   +----------------------+                    +----------------------+
              OSPF 영역(area) 0 안에서 서로 주소를 알려 줌
```

| 장비 | 인터페이스 | 주소 | 역할 |
|------|-----------|------|------|
| sw1 | lo | 10.0.0.1/32 | 장비의 대표 주소(루프백) |
| sw1 | eth1 | 192.168.12.1/30 | sw2와 잇는 선 |
| sw2 | lo | 10.0.0.2/32 | 장비의 대표 주소(루프백) |
| sw2 | eth1 | 192.168.12.2/30 | sw1과 잇는 선 |

- 컨테이너 이름은 `clab-lab1-sw1`, `clab-lab1-sw2`임

## 준비물
- Docker Desktop이 켜져 있어야 함(트레이의 고래 아이콘이 "running" 상태)  
- Windows 터미널(또는 PowerShell)을 열고 `wsl`을 입력해 WSL을 엶  
- 실습 폴더로 이동함. 아래 `<사용자>`는 내 Windows 사용자 이름으로 바꿈  
  ```bash
  cd /mnt/c/Users/<사용자>/class/aidc/labs/lab1-ospf
  ```
- 다른 실습(lab2 등)이 떠 있으면 컴퓨터 자원을 아끼려고 해당 실습 폴더에서 끄고 시작함

## 따라 하기
1. 실습 환경을 띄움  
   ```bash
   ./clab.sh deploy -t lab1.clab.yml
   ```
   이렇게 나오면 성공: 마지막에 표가 나오고 `clab-lab1-sw1`, `clab-lab1-sw2`의 State가 `running`임  
   뜻: 스위치 2대가 컨테이너로 켜지고 선 하나로 이어짐  
   띄운 뒤 OSPF가 서로를 찾을 때까지 15초쯤 기다림

2. 이웃을 찾았는지 확인함  
   ```bash
   docker exec clab-lab1-sw1 vtysh -c "show ip ospf neighbor"
   ```
   이렇게 나오면 성공: 한 줄이 나오고 `State`가 `Full/-`임(시간 값은 바뀔 수 있음)  
   ```text
   Neighbor ID     Pri State           Up Time         Dead Time Address         Interface
   10.0.0.2          1 Full/-          15.436s           34.563s 192.168.12.2    eth1:192.168.12.1
   ```
   뜻: sw1이 sw2(10.0.0.2)를 이웃으로 찾았고, 서로 가진 길 정보를 완전히 맞췄다는 뜻(`Full`)임

3. sw1이 sw2의 주소를 배웠는지 확인함  
   ```bash
   docker exec clab-lab1-sw1 vtysh -c "show ip route 10.0.0.2/32"
   ```
   이렇게 나오면 성공: `Known via "ospf"`가 보이고, 다음 길이 `192.168.12.2, via eth1`임  
   ```text
   Routing entry for 10.0.0.2/32
     Known via "ospf", distance 110, metric 10, best
     * 192.168.12.2, via eth1, weight 1
   ```
   뜻: 이 길은 내가 적은 것이 아니라 OSPF가 sw2에게서 배운 것임. `ospf` 대신 `static`이 보이면 손으로 넣은 길임

4. 대표 주소끼리 통신해 봄  
   ```bash
   docker exec clab-lab1-sw1 ping -c 3 -I 10.0.0.1 10.0.0.2
   ```
   이렇게 나오면 성공: `3 packets transmitted, 3 packets received, 0% packet loss`  
   뜻: sw1의 대표 주소(10.0.0.1)에서 sw2의 대표 주소(10.0.0.2)로 갔다가 돌아오는 길이 양쪽 모두 열려 있음

5. 실습 환경을 끔  
   ```bash
   ./clab.sh destroy -t lab1.clab.yml --cleanup
   ```
   이렇게 나오면 성공: `Removed container name=clab-lab1-sw1`, `clab-lab1-sw2` 줄이 보임  
   뜻: 컨테이너를 지우고 실습 폴더 안의 임시 폴더(`clab-lab1`)도 지움

- 이 실습에는 `check.sh`, `reset.sh`, `fault-demo.sh`가 없음. 2 ~ 4번 확인이 검사 역할을 하고,  
  처음부터 다시 하려면 5번으로 끈 뒤 1번부터 다시 함

## 막혔을 때
1. `docker: command not found`나 연결 오류가 나면 Docker Desktop이 켜져 있는지 확인함  
2. `deploy`가 "already exists"라고 하면 이전 실습이 남아 있는 것이므로 5번 명령으로 끈 뒤 다시 띄움  
3. 이웃이 안 보이면(2번 출력이 비어 있음) 15초쯤 더 기다린 뒤 다시 입력함  
4. 3번 결과에 경로가 없으면 `docker exec -it clab-lab1-sw1 vtysh`로 들어가 `show ip ospf neighbor`를 다시 확인함  
5. 두 번 시도해도 안 되면 끄기(5번)와 띄우기(1번)를 차례로 다시 함(이 실습에는 `reset.sh`가 없음)

## 용어 풀이
| 용어 | 쉬운 말 |
|------|---------|
| 스위치 | 네트워크 장비를 서로 잇는 장비. 이 실습에서는 컨테이너 안의 FRR 프로그램이 스위치 역할을 함 |
| FRR | 리눅스에서 스위치의 길 찾기 기능을 해 주는 프로그램 |
| 컨테이너 | 한 컴퓨터 안에 따로 칸을 막아 돌리는 작은 가상 컴퓨터 |
| 인터페이스(eth1) | 장비에 달린 선 꽂는 구멍의 이름 |
| 루프백(lo) | 장비 안에 있는 가상의 구멍. 선이 끊겨도 꺼지지 않아서 장비의 대표 주소로 씀 |
| /30, /32 | 주소 뒤에 붙는 숫자로, 같은 망에 묶이는 주소 개수를 정함. /30은 장비 2대용, /32는 주소 한 개 |
| 라우팅(경로) | 목적지로 가려면 어느 이웃에게 넘길지 적어 둔 길 안내 |
| static 경로 | 사람이 직접 적어 넣은 길 안내 |
| OSPF | 이웃끼리 자기가 아는 길을 주고받아 길 안내를 저절로 만드는 방식 |
| 영역(area) | OSPF에서 함께 길을 나누는 장비들의 묶음. 이 실습은 area 0 하나뿐임 |
| 이웃(neighbor) | 선으로 이어져 서로 길을 주고받기로 한 상대 장비 |
| vtysh | FRR 스위치 안에 들어가 상태를 보고 설정하는 명령 도구 |
