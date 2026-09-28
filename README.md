# AWS 서버리스 관측성 & 자가복구 시스템

서버리스 API에 로그·메트릭·트레이스 기반 관측성을 구축하고, 배포 결함으로 에러율이 급증하면 사람 개입 없이 이전 정상 버전으로 자동 롤백하는 시스템입니다.

> 🚧 구현 진행 중 — 진행 단계는 [시스템 분석·설계서 12장](docs/시스템분석설계서.md#12-일정-wbs) 참고

## 아키텍처

```
Client → API Gateway (HTTP API) → Lambda:live 별칭 → DynamoDB
                                        │
                  CloudWatch Logs · Metrics · X-Ray
                                        │
                         CloudWatch Alarm (5xx 비율)
                                        │
                     EventBridge → 복구 Lambda → 별칭을 last-known-good 버전으로 롤백
                                 → SNS 이메일 알림
```

## 기술 스택

| 영역 | 사용 기술 |
|---|---|
| IaC | Terraform (S3 네이티브 state 락) |
| 컴퓨팅 | AWS Lambda (Python 3.12, 버전 + 별칭) |
| API / DB | API Gateway HTTP API, DynamoDB On-Demand |
| 관측성 | CloudWatch Logs/Metrics/Alarms/Dashboard, X-Ray, Powertools for AWS Lambda |
| 자가복구 | EventBridge, Lambda, SSM Parameter Store |
| CI/CD | GitHub Actions + OIDC (장기 Access Key 미사용) |

## 문서

- [시스템 분석·설계서](docs/시스템분석설계서.md) — 요구사항 명세, 타당성·비용 분석, 설계 원칙, 테스트 계획, RTM
- [상세 설계](docs/DESIGN.md) — 컴포넌트 설정, 배포 책임 분리, 구현 순서

## 디렉토리

```
bootstrap/   최초 1회 적용: state 버킷, GitHub OIDC Provider, CI용 IAM Role
docs/        분석·설계 문서
```
