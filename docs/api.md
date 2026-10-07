# API Reference

`api-service`'s HTTP API — a PHP 8.2 backend with no framework (`league/route` for routing). Every route is defined in `api-service/config/routes/*.php` and dispatched to a single-purpose controller in `api-service/src/Interface/Http/`.

## Conventions

- **Base URL**: `http://localhost:8080` in local dev (via `make up` / Docker Compose's `nginx` service), `VITE_API_URL` is how `web-user` is told where to find it. Every route below is relative to this base.
- **Content type**: every response is `application/json`, including errors.
- **CORS**: added by `CorsMiddleware` on every response (`Access-Control-Allow-Origin` reflects the configured `CORS_ALLOW_ORIGIN` env var, or `*` if unset; allowed methods are `GET, POST, OPTIONS`). An `OPTIONS` preflight request never reaches the PHP app at all — nginx (`docker/nginx/default.conf`) intercepts it directly and returns `204` with CORS headers reflecting the real request origin.
- **Error shape**: always `{"error": "<message>"}`. There's no error code/type field, just a human-readable message — see [Error reference](#error-reference) for which status codes mean what.
- **Auth**: none. Every endpoint is unauthenticated.

## Endpoints

### `GET /healthz`

Liveness/readiness check for container probes (used by `kubernetes/chart`'s `nginx`/`php` probes). Does **not** touch the database — a healthy response only means the PHP process is up, not that MySQL is reachable.

**Response — `200`**
```json
{ "status": "ok" }
```

---

### `GET /api/csat/{week}`
### `GET /api/csat/{year}/{week}`

Weekly CSAT score — across all years for that week number if `year` is omitted, or for one specific year/week pair if given.

**Path parameters**

| Name | Type | Constraint |
|---|---|---|
| `week` | int | route-constrained to digits (`{week:number}`); a non-numeric value 404s before the controller ever runs |
| `year` | int, optional | same digits-only route constraint |

**Formula**: `CSAT = (satisfied / total) × 100`, rounded to 2 decimal places, where a response is "satisfied" at score ≥ 4 on the 1–5 scale (2 = dissatisfied threshold ≤ 2, 3 = neutral). If there are zero responses for the requested week(/year), the score is `0.0`, not an error.

**Response — `200`**
```json
{ "week": 12, "year": 2026, "score": 87.5 }
```
`year` is `null` in the response when the request omitted it (i.e. the all-years-for-this-week form).

**Response — `400`** (validation failures, checked in this order; message is the exact string thrown)

| Condition | Message |
|---|---|
| `week` not in `1..53` | `Week number must be between 1 and 53.` |
| `year` given, not in `2000..<current year>` | `Year must be between 2000 and <current year>.` |
| `week` exceeds the real last ISO week of `year` (e.g. week 53 in a 52-week year) | `Week <week> is not valid for year <year>.` |

---

### `GET /api/static-pages`

Lists published static pages (About, Privacy, etc.) — unpublished pages never appear here (filtered at the repository level, not in the controller).

**Response — `200`**
```json
[
  { "slug": "about", "title": "About Us", "content": "<p>...</p>" },
  { "slug": "privacy", "title": "Privacy Policy", "content": "<p>...</p>" }
]
```
An empty array (`[]`) if there are no published pages, not an error.

---

### `POST /api/contact`

Submits a contact message. Persists it and returns its generated ID — there's no corresponding `GET` to read it back (write-only from the API's perspective).

**Request body**
```json
{ "name": "Jane Doe", "email": "jane@example.com", "message": "…at least 80 characters…" }
```
A missing key defaults to an empty string rather than erroring immediately — it still fails the domain validation below (e.g. a missing `name` becomes `Name cannot be empty`, a `422`, not a `400`).

**Response — `201`**
```json
{ "id": 42 }
```

**Response — `400`** — only when a *present* field is the wrong JSON type (e.g. `"name": 123` instead of a string):
```json
{ "error": "name, email and message must be strings." }
```

**Response — `422`** — domain validation failure (one message at a time, whichever fails first):

| Field | Rule | Message |
|---|---|---|
| `name` | non-empty after trimming | `Name cannot be empty` |
| `name` | 2–100 characters | `Name must be at least 2 characters long` / `Name must not exceed 100 characters` |
| `name` | no digits or any of `` ^ < , @ / { } ( ) [ ] ! & \ ` ~ * $ % ? = > : \| ; # " `` | `Special characters and numbers are not allowed in the name` |
| `email` | must pass PHP's `FILTER_VALIDATE_EMAIL` | `Invalid email` |
| `message` | non-empty after trimming | `Message cannot be empty` |
| `message` | 80–2000 characters | `Message must be at least 80 characters long` / `Message must not exceed 2000 characters` |

Stored email addresses are lowercased; everything else is stored as submitted (trimmed).

## Error reference

| Status | Meaning | Where it comes from |
|---|---|---|
| `400` | Malformed input the controller itself rejects before calling any use case | Inline in `CalculateCsatController`/`SubmitContactController` |
| `404` | No route matches the path | League Route's `NotFoundException`, caught by the global `ExceptionHandler` |
| `405` | Route exists, wrong HTTP method | League Route's `MethodNotAllowedException`, same handler |
| `422` | Input is well-formed JSON/types but fails a domain rule | `ContactMessageException`, thrown by the `Name`/`Email`/`Message` value objects |
| `500` | Anything else unhandled | `ExceptionHandler`'s catch-all — logged via Monolog (with an `error_log` fallback if logging itself fails) before the response is built |

## Implementation notes

- `400`s are handled *inside* the controller (catching `InvalidArgumentException` from the `WeekOfYear`/`Year` value objects, or checking JSON types directly) — they never reach `ExceptionHandler`. Only `404`/`405`/`422`/`500` go through it.
- `ExceptionHandler::buildResponse()` hardcodes `422` for every `ContactMessageException`, regardless of the exception's own `statusCode()` method (which defaults to `422` anyway — nothing in the codebase currently constructs one with a different code).
- There's no API versioning (no `/v1/` prefix or `Accept` header negotiation) — all four routes above are the entire public surface.
