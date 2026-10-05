# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in `api-service/`. See the root `CLAUDE.md` for the monorepo overview and how to run the stack.

## Stack (PHP 8.2, DDD, no framework)

Custom-assembled stack: `league/route` for routing, `php-di` for the DI container, `doctrine/dbal` (no ORM) for persistence, `doctrine/migrations` for schema, `monolog` for logging. Entry point is `public/index.php`, which loads env vars, builds the container (`config/container.php`), builds the router (`config/routes.php`, which auto-registers every file under `config/routes/*.php`), and dispatches the PSR-7 request.

Commands (run inside the `php` container, e.g. via `make shell`, or prefix with `docker compose exec php`):

```bash
composer install                    # make composer-install
bin/phpunit                         # make phpunit-test — run all tests
bin/phpunit --filter TestName       # run a single test
bin/phpunit tests/Unit/Domain/Csat/ValueObject/CsatScoreTest.php  # run one file
bin/php-cs-fixer fix                # make format — PSR-12 formatting
bin/phpstan analyse src             # make analyse — level 8 static analysis
bin/console csat:import <file>      # CLI import command (see Interface/Cli)
bin/db-migrations migrations:migrate
```

## Layering (Domain-Driven Design)

Code under `src/` is organized by domain module first (`Contact`, `Content`, `Csat`), then by layer:

- **`Domain/`** — entities, value objects, repository *interfaces*, domain exceptions. No framework or infrastructure dependencies. Value objects (`Email`, `Slug`, `Score`, `WeekOfYear`, …) enforce their own invariants in the constructor and throw domain exceptions on invalid input.
- **`Application/`** — use cases (`SubmitContactMessageUseCase`, `CalculateWeeklyCsatScoreUseCase`, `ImportCsatResponsesUseCase`, …) that orchestrate domain objects and repositories. One use case = one action; use cases are autowired into the DI container by class name (see `config/container.php`).
- **`Infrastructure/`** — concrete implementations: `Persistence/Dbal/*` repository implementations, `Csv/CsatCsvParser`, HTTP middleware (`CorsMiddleware`), `ExceptionHandler`, `JsonResponse`.
- **`Interface/`** — the outermost layer that talks to the outside world: `Http/*Controller` classes (invoked by League Route via the DI container) and `Cli/*Command` classes (Symfony Console).

To add a new endpoint: add a route mapping in `config/routes/{module}.php` (or a new file — it's auto-discovered), a controller in `Interface/Http/`, a use case in `Application/{Module}/UseCase/`, and wire the use case/repository binding into `config/container.php`.

## Testing layers (`tests/`)

- **`Unit/`** — pure domain logic, no container/DB (e.g. value object validation).
- **`Integration/`** — exercises use cases and repositories against a real MySQL connection, built through the DI container (extend `IntegrationTestCase`).
- **`Functional/`** — full HTTP-level tests dispatching through `AppKernel` (a router built the same way as `public/index.php`) against a real DB (extend `FunctionalTestCase`).

Integration/Functional tests load `.env.test` (via `APP_ENV=test` set in `phpunit.xml.dist`) and both auto-create/truncate the schema on first run (`CreateDatabaseTrait`) — a reachable MySQL instance matching `.env.test` credentials is required to run anything beyond `Unit/`.

`phpstan.neon.dist` excludes `src/Infrastructure/Http/JsonResponse.php` from analysis; everything else in `src/` is checked at level 8.

## CI

`.github/workflows/ci-api.yml` runs on every push to `main` and on manual `workflow_dispatch`: `quality` (php-cs-fixer dry-run + phpstan) → `unit-tests` → `integration-tests` → `functional-tests` → `publish`, each gated on the previous job succeeding. All jobs except `publish` run directly on `ubuntu-24.04` (not in a container — `shivammathur/setup-php` installs PHP onto the bare runner and isn't designed to reconfigure an already-built PHP image). The DB-backed jobs use a port-mapped `mysql:8.0` service and add a `127.0.0.1 mysql` entry to `/etc/hosts` so `.env.test`'s `DB_HOST=mysql` resolves without editing app config; `.env.test` itself is generated in CI via `cp .env.example .env.test`. JUnit reports, coverage (clover + HTML, via pcov), and `var/log/*.log` are uploaded as workflow artifacts (3-day retention). Shared setup steps (PHP, Composer cache, `composer install`) live in `.github/actions/setup-api`.

`publish` (main branch only) builds `docker/php/Dockerfile`'s `prod` target (no xdebug, `composer install --no-dev`) and `docker/nginx/Dockerfile`, pushing both to `ghcr.io/<owner>/<repo>/csat-{php,nginx}`, tagged by commit SHA and `latest`.
