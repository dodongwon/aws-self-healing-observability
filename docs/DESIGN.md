# AWS 서버리스 관측성(Observability) & 자가복구 시스템 — 상세 설계도 (v2)

> v1(`~/Downloads/aws-observability-portfolio-design.md`) 대비 변경 요약은 맨 아래 **부록 A** 참고.

## 0. 프로젝트 개요

| 항목 | 내용 |
|---|---|
| 목적 | 클라우드/네트워크 직무 포트폴리오 |
| 핵심 컨셉 | 서버리스 API + 관측성(로그·메트릭·트레이스) + 이상탐지 시 자동 롤백 + CI/CD |
| 월 예산 목표 | 1~2만원 미만 (AWS 인프라 기준) — **AWS Budgets 알림으로 강제** |
| IaC | Terraform ≥ 1.10, AWS provider ~> 6.0 |
| CI/CD | GitHub Actions + OIDC (장기 Access Key 미사용) |
| 런타임 | Python 3.12 + Powertools for AWS Lambda (Logger / Tracer / Metrics) |
| 리전 | ap-northeast-2 (서울) |
| 구현 방식 | Claude Code로 코드 작성·`terraform plan`·테스트 실행까지 진행, `apply`와 push는 본인 확인 후 실행 |

---

## 1. 전체 아키텍처

```
  GitHub PR ──▶ ci.yml (lint/test/fmt/validate/plan, 읽기전용 Role)
  main merge ─▶ deploy.yml (terraform apply → 코드 배포 → 스모크 테스트 → alias 전환)
                                   │
┌────────┐   ┌──────────────┐   ┌──────────────────┐   ┌──────────┐
│ Client │──▶│ API Gateway  │──▶│ Lambda:live 별칭  │──▶│ DynamoDB │
└────────┘   │  (HTTP API)  │   │  (버전 N)         │   └──────────┘
             └──────┬───────┘   └────────┬─────────┘
                    │ access log          │ 구조화 로그 / EMF 메트릭 / X-Ray
                    ▼                     ▼
             ┌─────────────────────────────────────┐
             │ CloudWatch Logs · Metrics · X-Ray   │
             │ + Dashboard 1개                      │
             └──────────────────┬──────────────────┘
                                │ 임계치 초과
                                ▼
                        CloudWatch Alarm
                                │ (Alarm State Change 이벤트)
                                ▼
                          EventBridge 규칙
                    ┌───────────┴───────────┐
                    ▼                       ▼
         복구 Lambda (alias 롤백)     SNS → 이메일
                    │
                    └──▶ SSM: last-known-good 버전 조회
```

---

## 2. 컴포넌트별 상세 설계

### 2.1 API Gateway — HTTP API로 확정
- REST API 대비 요청 단가 약 70% 저렴하고 설정이 단순함
- 엔드포인트: `GET /health`, `GET /items/{id}`, `POST /items`
- 통합 대상: Lambda **`live` 별칭 ARN** (버전 직접 호출 X → 롤백 시 API 설정 변경 불필요)
- 스로틀링: 스테이지 기본 라우트 설정 `rate=10`, `burst=20` (비용 폭주 방지)
- Access Log → CloudWatch Logs (보존 14일, JSON 포맷)
- 참고: HTTP API는 X-Ray 트레이싱을 지원하지 않음 → 트레이스는 Lambda에서 시작 (2.4)

### 2.2 Lambda (비즈니스 로직)
- 메모리 256MB, 타임아웃 10초
- `publish = true`로 매 배포마다 **불변 버전** 생성, `live` 별칭이 현재 서비스 버전을 가리킴
- 설정값은 환경변수(테이블명 등) + SSM Parameter Store Standard(무료). Secrets Manager는 사용 안 함
- Powertools Layer 사용 → 배포 패키지는 자체 코드만 (콜드스타트·용량 최소화)
- **장애 주입 장치**: 환경변수 `FAULT_RATE`(기본 `0`). 0.5로 설정한 버전을 배포하면 50% 확률로 500 반환
  - 환경변수는 버전에 함께 고정되므로, 이전 버전으로 롤백하면 장애도 같이 사라짐 → 자가복구 데모에 그대로 사용

### 2.3 DynamoDB
- 테이블: `items` (PK: `id`), On-Demand, PITR 미사용(비용·포트폴리오 규모 고려)
- Terraform 락 테이블은 **만들지 않음** — Terraform 1.10+의 S3 네이티브 락(`use_lockfile = true`) 사용

| 속성 | 타입 | 설명 |
|---|---|---|
| id | String (PK) | 아이템 고유 ID (UUID) |
| createdAt | String | ISO8601 |
| status | String | active / archived |
| payload | Map | 실제 데이터 |

### 2.4 관측성 (로그 · 메트릭 · 트레이스)
| 요소 | 구현 | 비고 |
|---|---|---|
| 로그 | Powertools Logger → JSON 구조화 로그, `correlation_id`(요청 ID) 포함 | Log Group은 Terraform이 먼저 생성해 보존 14일 지정 |
| 메트릭(기본) | `AWS/ApiGateway`의 `Count`, `5xx`, `4xx`, `Latency` / `AWS/Lambda`의 `Errors`, `Duration`, `Throttles` | 메트릭 필터 불필요 — HTTP API가 기본 제공 |
| 메트릭(커스텀) | Powertools Metrics(EMF)로 `ItemsCreated` 등 1~2개 | 로그 기반이라 PutMetricData 호출 비용 없음 |
| 트레이스 | Lambda Active Tracing + Powertools Tracer → DynamoDB 호출 구간까지 서브세그먼트 | 기본 샘플링(초당 1건 + 5%) 유지 |
| 대시보드 | 에러율 / p99 지연 / 호출수 / 현재 alias 버전 로그 위젯 | 무료 3개 한도 내 1개 |

### 2.5 자가복구 (Alarm → EventBridge → 복구 Lambda)
구현 시나리오는 2개로 한정 (v1의 DynamoDB 쓰로틀 시나리오는 On-Demand 모드에서 조치할 내용이 없어 제외).

**알람 설계 원칙: 자동조치 알람은 보수적으로, 알림 전용 알람은 민감하게**

| 알람 | 조건 | 동작 |
|---|---|---|
| ① `5xx-rate` (롤백용) | Metric Math `IF(Count >= 10, 5xx / Count * 100, 0) > 5` — 5분 합계 주기, 2개 중 2개 초과 | 자동 롤백 + 이메일 |
| ② `5xx-count` (알림용) | `5xx >= 3` (5분 합계, 요청 수 무관) — 1개 중 1개 | 이메일만 |
| ③ `p99-latency` (알림용) | `Latency p99 > 3000ms` — 5분 주기, 3개 중 2개 | 이메일만 |

- ①은 최소 요청 수 조건으로 저트래픽 오탐(1건 실패 = 100%)을 막고, 5분 합계 기준이라 저트래픽에서도 판단 가능
- ②는 ①이 판단하지 못하는 저트래픽 구간의 장애를 메움 — 오탐 비용이 이메일 1통뿐이라 민감하게 설정
- 모든 알람 `treat_missing_data = notBreaching` (트래픽 없음 ≠ 장애)
- 모든 알람은 `alarm_actions`로 SNS에 **직접** 통보 → 복구 Lambda가 실패해도 장애 통보는 보장

**시나리오 1 — 5xx 급증 시 자동 롤백 (핵심)**
- 트리거: 알람 ①
- EventBridge 규칙: `source = aws.cloudwatch`, `detail-type = CloudWatch Alarm State Change`, `state.value = ALARM`, 알람 이름 일치
- 복구 Lambda 동작:
  1. SSM `/obs-app/last-known-good-version` 조회
  2. 현재 `live` 별칭 버전과 같으면 아무것도 안 함 (중복 실행·루프 방지)
  3. 다르면 `UpdateAlias`로 롤백 → 결과(이전/이후 버전, 알람명)를 구조화 로그 + SNS로 통보
- 복구 Lambda IAM: 대상 함수 한 개에 대한 `lambda:GetAlias`, `lambda:UpdateAlias`, 해당 SSM 파라미터 `ssm:GetParameter`, SNS `Publish`만 허용

**시나리오 2 — 저트래픽 에러 / p99 지연 초과 시 알림만**
- 트리거: 알람 ②, ③ → SNS 직접 통보 (EventBridge·복구 Lambda 거치지 않음)
- 자동조치보다 사람 판단이 맞는 케이스

**last-known-good 갱신 규칙**: deploy.yml에서 새 버전 스모크 테스트 통과 → alias 전환 → 그 버전을 SSM에 기록. 즉 "스모크 테스트 통과한 마지막 버전"이 롤백 기준.

### 2.6 알림 · 비용 가드
- SNS 토픽 `alerts-topic` → 이메일 구독 (구독 확인 메일 수동 승인 필요)
- **AWS Budgets**: 월 $10 예산, 실제 50%/100% 및 예측 100% 도달 시 이메일 (Budgets 2개까지 무료)

---

## 3. 배포 책임 분리 (Terraform vs CI)

v1은 `terraform apply`와 `aws lambda update-function-code`가 같은 리소스를 건드려 드리프트가 생기는 구조였음. 아래처럼 소유권을 나눔.

| 대상 | 소유자 | 방법 |
|---|---|---|
| 모든 인프라 (API, 테이블, 알람, IAM, 함수 설정) | Terraform | `apply` |
| Lambda 함수 **코드** | CI (deploy.yml) | Terraform은 초기 placeholder zip만 넣고 `ignore_changes = [filename, source_code_hash]` |
| `live` 별칭이 가리키는 버전 | CI + 복구 Lambda | Terraform은 `ignore_changes = [function_version]` |
| last-known-good SSM 값 | CI | Terraform은 파라미터만 생성, `ignore_changes = [value]` |

→ 복구 Lambda가 롤백한 뒤 누가 `terraform apply`를 돌려도 롤백이 되돌려지지 않음.

---

## 4. 디렉토리 구조

```
.
├── bootstrap/               # 최초 1회 로컬 apply (state 버킷, OIDC Provider, CI용 IAM Role 2개)
├── infra/
│   ├── modules/
│   │   ├── app/             # Lambda(앱) + alias + IAM + Log Group + DynamoDB
│   │   ├── api/             # HTTP API + 스테이지 + access log
│   │   ├── monitoring/      # Alarm, Dashboard, EventBridge 규칙, 복구 Lambda
│   │   └── notification/    # SNS + Budgets
│   └── envs/dev/            # backend(S3, use_lockfile), 모듈 호출, tfvars
├── src/
│   ├── app/                 # 비즈니스 로직 Lambda
│   └── remediation/         # 복구 Lambda
├── tests/                   # pytest (moto로 DynamoDB/Lambda 모킹)
├── scripts/
│   ├── load.sh              # 부하 생성 (데모용)
│   └── chaos.sh             # FAULT_RATE 버전 배포 → 롤백 관찰
└── .github/workflows/{ci.yml, deploy.yml}
```

- 모듈 5개 → 4개로 축소: DynamoDB 테이블은 1개뿐이라 `app` 모듈에 포함
- `bootstrap/`을 분리한 이유: CI가 쓸 OIDC Role과 state 버킷은 CI보다 먼저 존재해야 함 (닭과 달걀 문제)

---

## 5. CI/CD (GitHub Actions)

### 5.1 IAM Role 2개 (OIDC)
| Role | Trust `sub` 조건 | 권한 |
|---|---|---|
| `gha-plan-role` | `repo:<OWNER>/<REPO>:pull_request` | ReadOnlyAccess + state 버킷 읽기/락 파일 쓰기 |
| `gha-deploy-role` | `repo:<OWNER>/<REPO>:ref:refs/heads/main` | 프로젝트 리소스(이름 접두사 `obs-app-*`)에 한정된 쓰기 권한 |

- `aud = sts.amazonaws.com` 조건 필수, 와일드카드 `sub` 금지

### 5.2 ci.yml (PR)
1. checkout → Python 설치 → `ruff check` + `pytest`
2. `terraform fmt -check -recursive`, `terraform validate`
3. `gha-plan-role`로 `terraform plan` → 결과를 `$GITHUB_STEP_SUMMARY`와 PR 코멘트(`actions/github-script`)로 게시

### 5.3 deploy.yml (main merge)
1. `gha-deploy-role` 획득 → `terraform apply -auto-approve`
2. `src/app` zip → `aws lambda update-function-code --publish` → 새 버전 번호 N 획득
3. **스모크 테스트**: `aws lambda invoke --qualifier N`로 health 이벤트 직접 호출 (alias 전환 전에 검증)
4. 통과 시 `update-alias live → N`, SSM last-known-good = N
5. 실패 시 alias 유지(기존 버전 그대로 서비스) + 워크플로 실패 처리
6. `concurrency: deploy` 설정으로 동시 배포 방지

---

## 6. 비용 추정 (개인 포트폴리오 트래픽 기준)

| 서비스 | 예상 월 비용 |
|---|---|
| Lambda / API Gateway(HTTP) / DynamoDB / SNS / X-Ray | 무료 티어 또는 사실상 0원 |
| CloudWatch Logs·Alarm·Dashboard | 무료 한도 내 (로그 5GB, 알람 10개, 대시보드 3개) |
| S3 (Terraform state) | 수십 원 |
| AWS Budgets | 무료 (2개) |
| **합계** | **대부분 0원, 보수적으로 5천원 이내** |

**과금 폭탄 방지 체크리스트**
- VPC 미사용 → NAT Gateway 생성 금지
- RDS / EKS / Fargate / EC2 상시 실행 금지
- 모든 Log Group 보존 14일 (Lambda가 자동 생성하기 전에 Terraform으로 먼저 생성)
- X-Ray 기본 샘플링 유지 (100% 금지)
- `load.sh`는 요청 수 상한(예: 2,000건) 하드코딩
- 데모 끝나면 `FAULT_RATE=0` 버전이 live인지 확인

---

## 7. 구현 순서 (Claude Code 기준)

각 단계는 **완료 기준**을 만족해야 다음으로 넘어감. `apply`·push는 매번 본인 확인 후 실행.

| 단계 | 작업 | 완료 기준 |
|---|---|---|
| 0 | 로컬 도구 확인 (AWS CLI, Terraform ≥ 1.10, Python 3.12, gh), `aws sts get-caller-identity` | 계정 ID 출력 |
| 1 | `bootstrap/` 작성·apply | state 버킷, OIDC Provider, Role 2개 생성 |
| 2 | `src/app` + pytest | 로컬 테스트 통과 |
| 3 | `modules/app`, `modules/api` + `envs/dev` apply | `curl /health` 200 |
| 4 | GitHub repo 연결, ci.yml / deploy.yml | PR에 plan 코멘트, merge 시 자동 배포 성공 |
| 5 | `modules/notification`, `modules/monitoring`(알람·대시보드) | 이메일 구독 확인, 대시보드에 그래프 표시 |
| 6 | 복구 Lambda + EventBridge | `chaos.sh` 실행 → 수 분 내 alias 자동 롤백 + 이메일 수신 |
| 7 | README, 아키텍처 다이어그램, 데모 캡처(대시보드·X-Ray 트레이스 맵·롤백 로그) | 문서 완성 |

---

## 8. 포트폴리오 강조 포인트

- **IaC**: 인프라 전체를 모듈화된 Terraform으로 관리, bootstrap/앱 인프라 분리
- **관측성**: 로그(구조화)·메트릭(기본+EMF 커스텀)·트레이스(X-Ray) 3요소 모두 구현
- **자가복구**: 장애 주입 → 알람 → 자동 롤백까지 사람 개입 없이 동작하는 것을 **재현 가능한 스크립트로 시연**
- **배포 안전성**: 불변 버전 + 별칭, 전환 전 스모크 테스트, Terraform/CI 소유권 분리로 드리프트 제거
- **보안**: OIDC(장기 키 없음), plan/deploy Role 분리, 복구 Lambda 최소권한
- **비용 설계**: 서버리스 선택 근거와 월 비용을 수치로 제시, Budgets 알림으로 상한 강제

---

## 부록 A. v1 → v2 변경 사항

| 항목 | v1 | v2 | 이유 |
|---|---|---|---|
| 구현 방식 | Free 플랜 복붙 전제 | Claude Code 사용 | 현재 Claude Code 사용 중 |
| API 종류 | REST/HTTP 미정 | HTTP API 확정 | 비용·단순성 |
| X-Ray 범위 | API GW → Lambda → DynamoDB | Lambda → DynamoDB | HTTP API는 X-Ray 미지원 |
| 4xx/5xx 메트릭 | 커스텀 메트릭 필터 | API GW 기본 메트릭 | 불필요한 설정 제거 |
| Terraform 락 | DynamoDB 락 테이블 | S3 네이티브 락 | Terraform 1.10+ 기능, 리소스 1개 감소 |
| 코드 배포 | apply와 CLI가 같은 리소스 수정 | 소유권 분리 + `ignore_changes` | 드리프트·롤백 무효화 방지 |
| 롤백 기준 | "이전 정상 버전" (정의 없음) | SSM last-known-good | 스모크 테스트 통과 버전으로 명확화 |
| 에러율 알람 | 5% 5분 단일 알람 | 롤백용(5분 합계 ≥10요청 & >5%, 2/2) + 알림용(5xx ≥3건) 분리 | 저트래픽 오탐 방지 + 저트래픽 장애 미탐 방지 |
| 복구 시나리오 | 3개 (DynamoDB 쓰로틀 포함) | 2개 | On-Demand라 쓰로틀 시 조치할 게 없음 |
| 장애 재현 | 없음 | `FAULT_RATE` + chaos.sh | 자가복구 시연 가능 |
| CI Role | 1개 | plan(읽기) / deploy(쓰기) 2개 | 최소권한 |
| 비용 가드 | 체크리스트만 | + AWS Budgets 알림 | 자동 경고 |
| Terraform 모듈 | 5개 | 4개 + bootstrap | 테이블 1개라 app에 통합, OIDC 선행 문제 해결 |
| 오류 | "5장 시간 추정치" 참조 | 제거, 단계별 완료 기준 추가 | 존재하지 않는 장 참조 |
