.PHONY: help up down dev prod logs shell test lint migrate

help:           ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup:          ## First-time setup: copy .env and build images
	cp -n .env.example .env || true
	docker compose build

up:             ## Start all services in dev mode (hot reload)
	docker compose up

down:           ## Stop all services
	docker compose down

dev:            ## Start in dev mode, detached
	docker compose up -d
	@echo "Backend:        http://localhost:8000"
	@echo "API Docs:       http://localhost:8000/docs"
	@echo "Redis UI:       http://localhost:8081"

prod:           ## Start in production mode
	docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

logs:           ## Tail logs for all services
	docker compose logs -f

logs-backend:   ## Tail backend logs only
	docker compose logs -f backend

shell:          ## Open shell inside backend container
	docker compose exec backend bash

test:           ## Run test suite inside container
	docker compose exec backend \
	  pytest --cov=app --cov-report=term-missing -v

lint:           ## Run ruff linter and mypy
	docker compose exec backend ruff check app/
	docker compose exec backend mypy app/

migrate:        ## Apply Supabase migrations (requires supabase CLI)
	supabase db push

build-prod:     ## Build production image only
	docker compose -f docker-compose.yml -f docker-compose.prod.yml build

health:         ## Check backend health
	curl -s http://localhost:8000/health | python3 -m json.tool
