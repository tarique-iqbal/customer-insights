# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in `web-user/`. See the root `CLAUDE.md` for the monorepo overview and how to run the stack.

## Stack (React 19 + TypeScript + Vite)

```bash
npm install
npm run dev              # vite dev server, or: make npm-test for tests via docker
npm run build
npm test                 # vitest
npm run test:watch
npm run test:coverage
npx vitest run path/to/file.test.tsx   # run a single test file
npx vitest run -t "test name"          # run tests matching a name
npm run lint              # eslint ./src --ext .ts,.tsx
```

Path alias `@/*` maps to `src/*` (configured in both `vite.config.ts` and `tsconfig.json`).

## Structure

- **`api/`** — one module per backend resource (`csatService.ts`, `contactUs.ts`, `staticPages.ts`), all built on a shared `axios` instance in `api/http.ts`. `baseURL` resolves `window.__ENV__.VITE_API_URL` (runtime config, written by the prod image's container entrypoint — see `docker/web-user/generate-env.sh`) first, falling back to `import.meta.env.VITE_API_URL` for the dev server/Compose.
- **`pages/`** — route-level components, matched 1:1 with `routes/AppRoutes.tsx`.
- **`layouts/`**, **`components/`** — shared UI shell and reusable pieces.
- **`utils/`** — pure helpers (e.g. `dateUtils.ts`).
- Forms use `react-hook-form` + `zod` (via `@hookform/resolvers`); server state uses `@tanstack/react-query`.
- Tests live in a `__tests__/` folder next to the code they cover, using Vitest + Testing Library (jsdom environment, coverage via istanbul, setup in `src/setupTests.ts`).

## CI

`.github/workflows/ci-client.yml` runs on the same triggers as `ci-api.yml`: `quality` (`npm run lint`) → `test` (`npm run test:coverage`, extended with `--reporter=junit` for a JUnit report alongside the existing istanbul coverage output) → `build` (`npm run build`) → `publish`, each gated on the previous job succeeding. All jobs except `publish` run on `ubuntu-24.04` with Node 20 (matching `docker/web-user/Dockerfile`). Test report, coverage, and the `dist/` build output are uploaded as workflow artifacts (3-day retention). Shared setup steps (Node, npm cache, `npm ci`) live in `.github/actions/setup-client`.

`publish` (main branch only) builds `docker/web-user/Dockerfile`'s `prod` target (static `vite build` served by nginx, not the dev server) and pushes to `ghcr.io/<owner>/<repo>/csat-web-user`, tagged by commit SHA and `latest`.
