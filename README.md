# Customer Satisfaction Score – Monorepo

[![CI (api-service)](https://github.com/tarique-iqbal/customer-insights/actions/workflows/ci-api.yml/badge.svg)](https://github.com/tarique-iqbal/customer-insights/actions/workflows/ci-api.yml)
[![CI (web-user)](https://github.com/tarique-iqbal/customer-insights/actions/workflows/ci-client.yml/badge.svg)](https://github.com/tarique-iqbal/customer-insights/actions/workflows/ci-client.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Customer Satisfaction Score (CSAT) is a key performance indicator that measures how satisfied customers are with a company's products, services, or experiences.

- **Formula**:
  `CSAT = (Number of Satisfied Customers / Total Responses) × 100`
- **Segmentation** — uses a 1–5 scale:
  - Satisfied = 4–5
  - Neutral = 3
  - Dissatisfied = 1–2
- **Use case**: measures short-term satisfaction with a product/service.

This repo has two independent apps that talk to each other purely over HTTP — there is no shared build:

- **`api-service/`** — PHP 8.2 backend API (Domain-Driven Design, no framework)
- **`web-user/`** — React 19 + TypeScript frontend (Vite)

## Tech Stack

| Area | Stack |
|---|---|
| Backend (`api-service/`) | PHP 8.2, Composer |
| | `league/route` (routing), `php-di` (DI container), `doctrine/dbal` + `doctrine/migrations` (persistence, no ORM), `monolog` (logging) |
| | MySQL 8.0 |
| | PHPUnit, PHPStan (level 8), PHP-CS-Fixer |
| Frontend (`web-user/`) | React 19, TypeScript, Vite |
| | `react-hook-form` + `zod`, `@tanstack/react-query` |
| | Vitest + Testing Library, ESLint |
| Infrastructure | Docker Compose (`php`, `nginx`, `mysql`, `web-user` services) |

## Project Structure

```
customer-insights/
├── api-service/               # API Service
│   ├── bin/                   # CLI tools or scripts
│   ├── config/                # App configuration files
│   ├── data/                  # Sample CSAT CSV files
│   ├── migrations/            # Database migration scripts
│   ├── public/                # Entry point
│   │   └── index.php          # Starts HTTP API
│   ├── src/
│   │   ├── Application/       # Application logic/use cases
│   │   ├── Domain/            # Domain models and interfaces
│   │   ├── Infrastructure/    # Database and external service integrations
│   │   └── Interface/         # API controllers
│   └── tests/
│       ├── Functional/
│       ├── Infrastructure/
│       ├── Integration/
│       └── Unit/
├── web-user/                  # React + Vite frontend
│   ├── public/
│   │   └── assets/
│   ├── src/
│   │   ├── api/               # each has its own __tests__
│   │   ├── components/
│   │   ├── layouts/
│   │   ├── pages/
│   │   ├── routes/
│   │   ├── utils/
│   │   ├── App.tsx
│   │   └── index.tsx
│   ├── index.html
│   ├── package.json
│   ├── tsconfig.json
│   └── vite.config.ts
├── docker/                    # Dockerfiles (php, nginx, web-user)
├── compose.yml
├── .gitignore
└── README.md
```

## Getting Started

### Prerequisites
- Docker and Docker Compose

### Setup
1. Copy `api-service/.env.example` to `api-service/.env.dev`.
2. Start the stack:
   ```bash
   make up
   ```
3. Once running:
   - API: http://localhost:8080
   - Web app: http://localhost:5173
   - MySQL: localhost:3306

See each app's own commands (single test/file runs, migrations, linting, etc.) in `api-service/CLAUDE.md` and `web-user/CLAUDE.md`.

## Testing & CI

- `api-service`: PHPUnit (`Unit`, `Integration`, `Functional`), PHPStan, PHP-CS-Fixer — see `.github/workflows/ci-api.yml`.
- `web-user`: Vitest, ESLint — see `.github/workflows/ci-client.yml`.

## Roadmap Ahead

- [ ] **Orchestration** — Kubernetes for auto-scaling, self-healing, and zero-downtime updates
  - [x] Local: deployed via [kind](https://kind.sigs.k8s.io/) — Helm chart, HPA, PodDisruptionBudgets, zero-downtime rollouts, CI-published images
  - [ ] Cloud: self-hosted K8s on EC2 (in progress), or managed via AWS EKS
- [ ] **Infrastructure as Code** — Terraform for reproducible cloud infrastructure
