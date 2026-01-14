# CheckUS EC2 t2.micro 성능 최적화 가이드

## 현재 상황

**EC2 인스턴스**: t2.micro (1GB RAM)
**실행 중인 서비스**:
- checkus-server (prod): 350MB
- checkus-server-dev (dev): 250MB
- Nginx, Docker, OS: ~400MB

## 즉시 적용 가능한 최적화 방안

### 1. 개발 서버 필요 시에만 실행 (권장)

**효과**: 250MB 메모리 즉시 확보

```bash
# 평소: prod만 실행
cd /home/ec2-user/checkus-infra
docker-compose up -d

# 개발 필요 시: dev 추가
docker-compose -f compose.yml -f compose.dev.yml up -d

# 개발 완료 후: dev 중지
docker-compose -f compose.dev.yml stop checkus-server-dev

# dev 완전히 제거
docker-compose -f compose.dev.yml down checkus-server-dev
```

### 2. JVM 메모리 최적화 (적용 완료)

#### 개발 서버: 350MB → 250MB 감소
```yaml
JAVA_OPTS=-Xmx250m -Xms100m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+UseStringDeduplication
```

**추가된 옵션**:
- `-XX:MaxGCPauseMillis=200`: GC 일시정지 시간 최대 200ms로 제한
- `-XX:+UseStringDeduplication`: 중복 문자열 제거로 메모리 절약

#### 프로덕션 서버: GC 튜닝
```yaml
JAVA_OPTS=-Xmx350m -Xms150m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+UseStringDeduplication -XX:G1HeapRegionSize=1M
```

**추가된 옵션**:
- `-XX:G1HeapRegionSize=1M`: 작은 힙 크기에 최적화된 Region 크기

### 3. 로깅 최적화 (적용 완료)

#### application-dev.yml 변경사항
- `show-sql: true → false`: SQL 로깅 비활성화
- `format_sql: true → false`: SQL 포맷팅 비활성화
- `root: INFO → WARN`: 전역 로그 레벨 축소
- `saomath.checkusserver: DEBUG → INFO`: 애플리케이션 로그 축소
- `org.hibernate.SQL: DEBUG → WARN`: Hibernate SQL 로그 최소화
- **TRACE 레벨 완전 제거**: 파라미터 값 로깅 비활성화

**효과**: CPU 사용량 감소, 로그 파일 I/O 감소

### 4. Swap 메모리 추가 (선택사항)

메모리 부족 시 완충 역할을 하는 1GB Swap 추가.

```bash
# EC2에서 실행
cd /home/ec2-user/checkus-infra
chmod +x add-swap.sh
./add-swap.sh
```

**swappiness 설정**: 10 (메모리 부족 시에만 Swap 사용)

**효과**:
- OOM Killer 방지
- 메모리 스파이크 대응
- 성능 저하는 있지만 서버 다운보다 나음

**주의**: Swap은 SSD가 아닌 EBS 볼륨에서 느림

### 5. Docker 컨테이너 메모리 제한 (선택사항)

현재는 JVM `-Xmx`로만 제한하고 있습니다. Docker 레벨에서도 제한하려면:

```yaml
# compose.yml
services:
  checkus-server:
    # ... 기존 설정
    deploy:
      resources:
        limits:
          memory: 400M  # JVM 350M + 버퍼 50M
        reservations:
          memory: 200M

# compose.dev.yml
services:
  checkus-server-dev:
    # ... 기존 설정
    deploy:
      resources:
        limits:
          memory: 300M  # JVM 250M + 버퍼 50M
        reservations:
          memory: 150M
```

**효과**: Docker가 컨테이너별 메모리를 강제로 제한하여 다른 서비스 영향 최소화

## 모니터링 명령어

### 실시간 메모리 사용량
```bash
# 시스템 전체 메모리
free -h

# Docker 컨테이너별
docker stats

# 연속 모니터링 (5초마다)
watch -n 5 'free -h && echo && docker stats --no-stream'
```

### 로그 확인
```bash
# 프로덕션 로그
docker logs -f checkus-server

# 개발 로그
docker logs -f checkus-server-dev

# 최근 100줄만
docker logs --tail 100 checkus-server
```

### 컨테이너 재시작
```bash
# 프로덕션만
docker-compose restart checkus-server

# 개발만
docker-compose -f compose.dev.yml restart checkus-server-dev

# 전체
docker-compose -f compose.yml -f compose.dev.yml restart
```

## 성능 개선 효과 예상

| 항목 | 변경 전 | 변경 후 | 절감량 |
|------|---------|---------|--------|
| dev JVM 메모리 | 350MB | 250MB | **-100MB** |
| dev 로깅 오버헤드 | ~20MB | ~5MB | **-15MB** |
| prod GC 효율 | 기본 | 최적화 | **응답시간 개선** |
| Swap (선택) | 0MB | 1024MB | **OOM 방지** |
| **총 절감** | - | - | **~115MB** |

## 향후 고려사항

### 단기 (1-3개월)
- [ ] dev 서버 사용 패턴 분석 (항상 필요한지 확인)
- [ ] Cloudflare CDN 캐싱으로 트래픽 감소
- [ ] API 응답 캐싱 (Redis 추가 시 고려)

### 중기 (3-6개월)
- [ ] t3.small 업그레이드 검토 (2GB RAM, $15/월)
- [ ] RDS 인스턴스 분리 (dev/prod)
- [ ] 프론트엔드 완전 분리 (Cloudflare Pages만 사용)

### 장기 (6개월 이상)
- [ ] AWS Fargate로 마이그레이션 (자동 스케일링)
- [ ] 멀티 AZ 배포 (고가용성)
- [ ] CloudWatch 모니터링 강화

## 배포 방법

### 1. 코드 변경 적용
```bash
# 로컬에서 커밋
cd checkus-infra
git add compose.yml compose.dev.yml add-swap.sh PERFORMANCE_OPTIMIZATION.md
git commit -m "perf: Optimize memory for t2.micro (dev 250MB, logging reduced)"
git push

cd ../checkus-server
git add src/main/resources/application-dev.yml
git commit -m "perf: Reduce dev logging for memory efficiency"
git push

# 서브모듈 참조 업데이트
cd ..
git add checkus-infra checkus-server
git commit -m "chore: Update submodules (performance optimization)"
git push
```

### 2. EC2에서 적용
```bash
# 1. 최신 코드 가져오기
cd /home/ec2-user/checkus-infra
git pull

# 2. dev 서버 중지 (선택사항)
docker-compose -f compose.dev.yml stop checkus-server-dev

# 3. Swap 추가 (선택사항, 한 번만)
chmod +x add-swap.sh
./add-swap.sh

# 4. 서버 재시작 (변경사항 적용)
docker-compose restart checkus-server
```

### 3. dev 서버 재빌드 (메모리 설정 변경 시)
```bash
# 서버 코드도 업데이트 필요
cd /home/ec2-user/checkus-server
git pull

# dev 이미지 재빌드 및 푸시 (로컬에서)
docker build -t 855673866113.dkr.ecr.ap-northeast-2.amazonaws.com/checkus/server:dev .
docker push 855673866113.dkr.ecr.ap-northeast-2.amazonaws.com/checkus/server:dev

# EC2에서 재시작
docker-compose -f compose.dev.yml pull
docker-compose -f compose.dev.yml up -d
```

## 트러블슈팅

### "OOMKilled" 에러 발생 시
```bash
# 1. 메모리 상태 확인
free -h
docker stats

# 2. 메모리 많이 쓰는 컨테이너 확인
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}"

# 3. dev 서버 중지
docker-compose -f compose.dev.yml down

# 4. Swap 추가 (아직 안 했다면)
./add-swap.sh

# 5. prod만 재시작
docker-compose up -d
```

### 응답 속도 느려짐
```bash
# GC 로그 확인
docker logs checkus-server 2>&1 | grep "GC"

# 메모리 부족하면 JVM 메모리 증가 (최대 400MB까지)
# compose.yml에서 -Xmx350m → -Xmx400m
```

### Swap 사용량이 계속 높음
```bash
# Swap 사용량 확인
swapon --show

# 근본 원인: 메모리 부족 → t3.small 업그레이드 검토
# 또는 dev 서버를 별도 인스턴스로 분리
```

## 참고 자료

- [Spring Boot Performance Tuning](https://docs.spring.io/spring-boot/docs/current/reference/html/deployment.html#deployment.efficient)
- [G1GC Tuning Guide](https://www.oracle.com/technical-resources/articles/java/g1gc.html)
- [AWS EC2 t2.micro Best Practices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html)
- [Docker Memory Management](https://docs.docker.com/config/containers/resource_constraints/)
