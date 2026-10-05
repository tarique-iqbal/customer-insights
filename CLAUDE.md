# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Module-specific detail lives in its own file: `api-service/CLAUDE.md` and `web-user/CLAUDE.md`. Claude Code loads whichever of those apply alongside this one, based on which files you're working with — this file stays scoped to what's genuinely repo-wide.

## Project overview

Customer Satisfaction Score (CSAT) monorepo: a PHP backend API (`api-service/`) and a React/Vite frontend (`web-user/`). CSAT is computed as `(Satisfied Customers / Total Responses) × 100`, using a 1–5 scale (Satisfied = 4–5, Neutral = 3, Dissatisfied = 1–2).

Two independent apps, each with its own dependency manager and toolchain — there is no shared build. They communicate purely over HTTP: `web-user` calls `api-service` via `VITE_API_URL` (default `http://localhost:8080` in dev, proxied through the `nginx` container).

## Running the stack

Docker Compose orchestrates four services: `php` (API, DDD app), `nginx` (serves the API on `:8080`), `mysql` (`:3306`), and `web-user` (Vite dev server on `:5173`).

```bash
make up          # docker compose up --build
make down
make restart      # down + up --build
make rebuild       # up --build --no-cache --force-recreate
make logs
make shell         # bash into the php container
```

Copy `api-service/.env.example` to the appropriate `.env.{APP_ENV}` file (`dev`/`test`) before running — `config/load_env.php` picks the file based on `APP_ENV` (defaults to `dev`). The file is optional, not required: real environment variables take precedence over it, and the app fails fast with a clear error if `DB_NAME`/`DB_USER`/`DB_PASS`/`DB_HOST` end up unset either way.

## CI

Each app has its own workflow (`ci-api.yml`, `ci-client.yml`), gated job-by-job — see `api-service/CLAUDE.md` and `web-user/CLAUDE.md` for the specifics of each.
