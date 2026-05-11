# HikariCP 알림 규칙 상세 (F545 Phase D)

## Rule 1 — HikariCP pool pending queue (critical)

**의도**: 풀에 대기 트랜잭션 발생 = 풀이 사실상 포화. cascade 전조. 1분 이상 지속되면 즉시 알림.

- **Folder**: `CheckUS`
- **Group**: `hikaricp` (30s evaluation)
- **Rule type**: `Grafana managed`
- **Query A** (Prometheus):
  ```promql
  max_over_time(
    hikaricp_connections_pending{
      application="checkus-server",
      environment="prod"
    }[1m]
  )
  ```
- **Expression B** (threshold): `A > 0`
- **For**: `1m`
- **Labels**: `severity=critical`, `team=backend`, `service=checkus-server`
- **Annotations**:
  - `summary`: `HikariCP 풀에 대기 트랜잭션 발생 — cascade 전조 ({{ $labels.instance }})`
  - `description`: `pending={{ $values.A.Value }} on instance {{ $labels.instance }} for 1m+. Pool exhaustion 위험. /actuator/prometheus 확인 + 진행 중 느린 쿼리 식별.`
- **Notification**: contact point `checkus-notice`

### 왜 `pending > 0` 인가
- HikariCP `connections_pending` = `getConnection()` 호출을 기다리는 스레드 수
- 정상 상태에서는 거의 항상 0
- 1 이상이 1분 지속 = pool 이 충분히 빨리 turnover 못 한다는 뜻 = cascade 직전 단계
- 2026-05-04 incident 에서 12:49 UTC pending 가 1 이상으로 올라간 직후 12:51 UTC 부터 ERROR cascade. 이 시점에 알림이 떴어야 함

## Rule 2 — HikariCP pool high utilization (warning)

**의도**: 풀 사용률 80% 초과가 지속되면 추세 경고. cascade 전조까지는 아니지만 트래픽/쿼리 패턴 변화 신호.

- **Folder**: `CheckUS`
- **Group**: `hikaricp`
- **Query A**:
  ```promql
  hikaricp_connections_active{application="checkus-server",environment="prod"}
    /
  hikaricp_connections_max{application="checkus-server",environment="prod"}
  ```
- **Expression B**: `A > 0.8`
- **For**: `2m`
- **Labels**: `severity=warning`, `team=backend`, `service=checkus-server`
- **Annotations**:
  - `summary`: `HikariCP 풀 사용률 {{ printf "%.0f%%" (mul $values.A.Value 100.0) }} 지속 ({{ $labels.instance }})`
  - `description`: `active/max ratio = {{ $values.A.Value }} 2m+. 트래픽 증가 또는 쿼리 점유 시간 증가 가능. 임박한 풀 고갈은 아니지만 Rule 1 트리거 전에 잡고자 함.`
- **Notification**: contact point `checkus-notice`

## Rule 3 — HikariCP connection timeout rate (warning, optional)

**의도**: timeout 발생률이 0보다 크면 이미 일부 요청이 실패하고 있다는 뜻. Rule 1 보다 늦지만, leak detection 못 따라가는 burst 케이스에 보조.

- **Folder**: `CheckUS`
- **Group**: `hikaricp`
- **Query A**:
  ```promql
  rate(hikaricp_connections_timeout_total{application="checkus-server",environment="prod"}[1m]) > 0
  ```
- **For**: `30s`
- **Labels**: `severity=warning`
- **Annotations**:
  - `summary`: `HikariCP getConnection timeout 발생 ({{ $labels.instance }})`

## False positive 점검

dev 환경에서 다음 시나리오에서 알림이 잘못 떨어지지 않는지 확인:
- 배포 직후 5분 (컨테이너 startup, JIT warmup)
- 야간 idle 시간 (트래픽 거의 없음, pending = 0 유지되어야 함)
- 정상 부하 (active 가 5-15 정도 왔다 갔다, pending 0)

## 알림 메시지 톤

Slack 알림 메시지는 다음을 포함하면 운영팀이 즉시 행동 가능:
- ⚠️/🚨 severity
- 어떤 instance (`checkus-blue` / `checkus-green` / `checkus-server-dev`)
- 현재 값 (pending 수, utilization %)
- 대시보드 직접 링크 (`{{ .DashboardURL }}` 또는 정적 URL)
- 의심 가는 조치 한 줄 (예: "느린 쿼리 확인: SHOW PROCESSLIST")
