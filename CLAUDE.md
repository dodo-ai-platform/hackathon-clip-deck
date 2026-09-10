# Project — Agent Guide

Этот репозиторий — проект AI Platform (Dodo). Инфраструктура управляется автоматически через Kubernetes-оператор.

## Ключевые файлы

- `PLATFORM.md` — **главный источник** информации об инфраструктуре: kubeconfig, credentials, endpoints, security constraints. Генерируется оператором автоматически.
- `k8s/` — Kubernetes манифесты (deployment, service). Применяются через CI.
- `.github/workflows/deploy.yaml` — CI: build → push в GHCR → kubectl apply.

## Как деплоить

Push в `main` → CI автоматически собирает образ, пушит в GHCR, деплоит на кластер.

## Что знать

- **SecurityContext обязателен** — Pod Security Standards: restricted. Без `runAsNonRoot`, `seccompProfile`, `drop: ALL` поды не запустятся.
- **Resources обязательны** — LimitRange задаёт дефолты, но лучше указать явно.
- **OTLP** — используй HTTP (порт 4318), не gRPC. Подробности в `PLATFORM.md`.
- **Secrets** — credentials для DB, MongoDB, Redis и bucket создаются оператором как K8s Secrets в namespace. Свои прикладные секреты (ключи внешних API и т.п.) тоже клади K8s Secret'ом в namespace проекта — это единственное место платформы для секретов, работает и в webstatic-проектах (без compute). Не коммить секреты в репо.
- **NetworkPolicy** — egress ограничен. Доступны: DNS; HTTP/HTTPS (80/443) **только в публичный интернет** (внутренние/служебные адреса кластера и cloud-metadata `169.254.169.254` отрезаны — нельзя достучаться до соседних проектов и kube-apiserver по 80/443); PostgreSQL (свой RDS, 5432); MongoDB (общий DDS, 8635 — если включён `mongodb`); MySQL (общий RDS, 3306 — если включён `mysql`); OTLP (Alloy 4317/4318 — **только на адрес коллектора из `PLATFORM.md`**, а не эти порты на произвольный хост); трафик внутри своего namespace (в т.ч. свой Redis — он работает подом в этом же namespace, отдельных правил не нужно). Остальное заблокировано. Поду можно **сознательно отобрать** выход из кластера меткой `ai.paas.dodois.io/egress: restricted` (интернет, LLM-прокси и общие БД пропадают; DNS, свой namespace и OTLP остаются) — для воркеров, исполняющих недоверенный/сгенерированный код; оговорки и рецепт — в PLATFORM.md и `dap-shipmaster`. Если включён `llmEgress` — дополнительно открыт egress к LLM-прокси (зарубежные LLM через `LLM_PROXY_URL`, см. PLATFORM.md / dap-shipmaster), тоже **только на адрес самого прокси**: свой `HTTP_PROXY` на чужой хост с портом 3128 не заработает.

## Правила

- Не редактировать `PLATFORM.md` — перезаписывается оператором
- Не коммитить `.env`, credentials, kubeconfig
- Язык коммитов: английский (conventional commits)
