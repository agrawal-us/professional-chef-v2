# Professional Chef Agent

AI-powered cooking assistant — FastAPI backend with Claude agents, Redis caching, and React Native iOS app.

## Quick Start (3 commands)

```bash
git clone https://github.com/your-org/chef-agent
cd chef-agent
make setup && make dev
```

## What's Running

| Service     | URL                        | Purpose                       |
|-------------|----------------------------|-------------------------------|
| Backend API | http://localhost:8000      | FastAPI + Claude agents       |
| API Docs    | http://localhost:8000/docs | Swagger UI                    |
| Redis UI    | http://localhost:8081      | Cache browser (dev only)      |

## Environment Setup

Copy `.env.example` to `.env` and fill in the values:

```bash
cp .env.example .env
```

### Required Variables

| Variable              | Where to get it                                             |
|-----------------------|-------------------------------------------------------------|
| `ANTHROPIC_API_KEY`   | https://console.anthropic.com → API Keys                   |
| `SUPABASE_URL`        | Supabase dashboard → Project Settings → API                |
| `SUPABASE_SERVICE_KEY`| Supabase dashboard → Project Settings → API → service_role |
| `SUPABASE_ANON_KEY`   | Supabase dashboard → Project Settings → API → anon         |
| `REDIS_PASSWORD`      | Choose any strong password (used locally and in prod)      |
| `JWT_SECRET`          | Generate with: `openssl rand -hex 32`                      |

### Optional Variables

| Variable            | Default       | Description                         |
|---------------------|---------------|-------------------------------------|
| `LOG_LEVEL`         | `debug`       | `debug`, `info`, `warning`, `error` |
| `MAX_IMAGE_SIZE_MB` | `10`          | Max upload size for ingredient photos |
| `ENVIRONMENT`       | `development` | Set to `production` in prod         |

## Common Commands

| Command              | Description                                  |
|----------------------|----------------------------------------------|
| `make setup`         | First-time setup: copy .env, build images    |
| `make dev`           | Start all services detached (hot reload)     |
| `make up`            | Start all services with logs in foreground   |
| `make down`          | Stop all services                            |
| `make logs`          | Tail logs for all services                   |
| `make logs-backend`  | Tail backend logs only                       |
| `make shell`         | Open bash shell in backend container         |
| `make test`          | Run pytest with coverage                     |
| `make lint`          | Run ruff + mypy                              |
| `make health`        | Check backend health endpoint                |
| `make prod`          | Start in production mode                     |
| `make build-prod`    | Build production images only                 |
| `make migrate`       | Apply Supabase migrations (requires CLI)     |

## Architecture

```
iOS App (Expo)
     │
     ▼
  Nginx (port 80/443)
  ├── Rate limiting (60 req/min API, 10 req/min uploads)
  ├── Large body support (15MB for image uploads)
  └── Proxy headers
     │
     ▼
FastAPI Backend (port 8000)
  ├── Claude AI Agents (Anthropic API)
  ├── Supabase (PostgreSQL + Auth + Storage)
  └── Redis (caching + rate limiting state)
```

## Running Tests

```bash
make test
```

Runs pytest with coverage report inside the backend container.

## Production Deployment

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

Production mode differences:
- 2 backend replicas with CPU/memory limits
- 4 uvicorn workers per replica
- Nginx reverse proxy with SSL termination
- No redis-commander (dev tool only)
- `LOG_LEVEL=info`

### Building production images

```bash
make build-prod
```
