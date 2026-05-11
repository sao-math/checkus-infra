# Grafana Cloud — HikariCP 모니터링 셋업 가이드

F545 의 사용자 측 셋업 가이드. Phase B/D 수행 시 참고.

## 0. 사전 조건

- checkus-server 가 `/actuator/prometheus` 를 Basic Auth 로 노출 (F545 Phase A 완료)
- Grafana Alloy 컨테이너가 prod/dev 양쪽 compose 에 들어가 있음 (Phase C 완료)
- GitHub Actions secrets 에 다음 5개 secret 등록 완료:
  - `PROMETHEUS_SCRAPE_USERNAME` — 기본 `prometheus`
  - `PROMETHEUS_SCRAPE_PASSWORD` — 임의 강한 문자열 (32자 이상)
  - `GRAFANA_CLOUD_PROM_URL` — Phase 1 에서 발급
  - `GRAFANA_CLOUD_PROM_USERNAME` — Phase 1 에서 발급
  - `GRAFANA_CLOUD_PROM_API_KEY` — Phase 1 에서 발급

## 1. Grafana Cloud 가입 (Phase B)

1. https://grafana.com/auth/sign-up/create-user 로 이동, `replaneducation@gmail.com` 으로 가입
2. Stack name: `checkus`, region: 가까운 region (예: `prod-us-east-0` 또는 `prod-ap-southeast-0`)
3. 좌측 메뉴 → **My Account** → **Cloud Portal**
4. 새로 만든 stack 선택 → **Prometheus** 카드 → **Details**
5. 다음 3개 값 캡처:
   - **Remote Write Endpoint** (예: `https://prometheus-prod-XX-prod-us-east-0.grafana.net/api/prom/push`) → `GRAFANA_CLOUD_PROM_URL`
   - **Username / Instance ID** (숫자) → `GRAFANA_CLOUD_PROM_USERNAME`
   - **Generate API token** 클릭 → 이름 `checkus-alloy-write` / scope `metricsPublisher` 권한만 → 발급 → `GRAFANA_CLOUD_PROM_API_KEY`

## 2. GitHub Actions Secrets 등록

위 5개 값을 다음 위치에 등록:
- `sao-math/checkus-server` repo → Settings → Secrets and variables → Actions → New repository secret
- 동일한 5개 secret 을 동일한 키 이름으로 등록 (prod/dev 공용)

## 2-bis. monitoring profile 활성화

`alloy` / `alloy-dev` 서비스는 `profiles: [monitoring]` 로 opt-in. 시크릿 등록 후 다음 둘 중 하나:

**옵션 A** — 워크플로 환경변수에 추가 (영구):
- `.github/workflows/cicd.yml`, `cicd-dev.yml`, `deploy-only.yml` 의 SSH 스크립트 마지막 `export ...` 블록 뒤에 다음 한 줄:
  ```bash
  export COMPOSE_PROFILES=monitoring
  ```

**옵션 B** — EC2 직접 실행 (1회성 테스트):
```bash
ssh checkus 'cd ~/checkus-infra && COMPOSE_PROFILES=monitoring docker compose up -d alloy'
ssh checkus 'cd ~/checkus-infra && COMPOSE_PROFILES=monitoring docker compose -f compose.dev.yml up -d alloy-dev'
```

## 3. Slack contact point 추가 (Phase D)

1. Grafana → 좌측 **Alerts & IRM** → **Alerting** → **Contact points** → **Add contact point**
2. Name: `checkus-notice`
3. Integration: `Slack`
4. **Webhook URL**: 기존 `#checkus-notice` Incoming webhook URL (1Password / SLACK_WEBHOOK_URL secret 과 동일하거나 별도 발급)
5. Test → "OK" 클릭 → Slack 채널에 테스트 메시지 도착 확인
6. **Save contact point**

## 4. 알림 규칙 추가 (Phase D)

자세한 PromQL/임계값은 `alert-rules.md` 참고. 요약:

| 이름 | 조건 | For | Severity | 채널 |
|---|---|---|---|---|
| `HikariCP pool pending queue` | `max_over_time(hikaricp_connections_pending{...,environment="prod"}[1m]) > 0` | 1m | critical | `#checkus-notice` |
| `HikariCP pool high utilization` | `(hikaricp_connections_active / hikaricp_connections_max){...,environment="prod"} > 0.8` | 2m | warning | `#checkus-notice` |

각 규칙은:
- **Folder**: `CheckUS`
- **Evaluation group**: `hikaricp` (interval 30s)
- **Labels**: `severity=critical|warning`, `team=backend`
- **Annotations**:
  - `summary`: 한 줄
  - `description`: PromQL 결과 + 대시보드 링크 (`{{ $values.A }}` 등)

## 5. 대시보드 import

- Grafana → 좌측 **Dashboards** → **New** → **Import**
- `hikaricp-dashboard.json` 파일 업로드
- Prometheus 데이터소스 선택
- **Import**

대시보드는 다음 패널 포함:
- 풀 사용률 (active vs max, 80% 임계선)
- pending 큐 (시간순 그래프)
- timeout 카운트 (rate)
- 컨테이너별 분리 (instance label)

## 6. 검증 (Phase E)

1. checkus-server prod 가 메트릭을 노출하는지 확인:
   ```bash
   ssh checkus
   curl -u "$PROMETHEUS_SCRAPE_USERNAME:$PROMETHEUS_SCRAPE_PASSWORD" \
        http://localhost:8081/actuator/prometheus | grep hikari
   ```
2. Alloy 컨테이너 로그에서 scrape success 확인:
   ```bash
   ssh checkus 'docker logs alloy --tail 50'
   ```
3. Grafana 의 **Explore** → Prometheus → query `hikaricp_connections_active{application="checkus-server"}` 실행 → 그래프 출력 확인
4. dev 에서 인위적 풀 압박 (Phase E 의 leak induction 시나리오 참고) → Slack 알림 도착 확인

## 7. 알림 끄고 싶을 때

- 일시 정지: Grafana → Alerting → Alert rules → 해당 규칙 → **Pause**
- 영구 삭제: 같은 위치에서 **Delete**

## Troubleshooting

- **Grafana Explore 에 메트릭이 안 보임**:
  - Alloy 컨테이너 로그 확인 → `target.scrape_failed` 가 있으면 Basic Auth 자격 또는 네트워크 문제
  - `docker exec alloy curl -u user:pass http://checkus-blue:8080/actuator/prometheus` 로 컨테이너 내부에서 scrape 시뮬레이션
- **Slack contact point Test 실패**: webhook URL 오타 또는 채널 권한 문제
- **알림이 떠야 하는데 안 옴**: Grafana → Alerting → **History** 에서 알림 평가 결과 확인. `Pending` → `Firing` 흐름 확인
