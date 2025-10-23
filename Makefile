.PHONY: help build up down logs restart dev test lint format precommit-install db-migrate docker-run

help:
	@echo "Makefile commands:"
	@echo "  make build            Build docker images (if Dockerfile present)"
	@echo "  make up               Start docker-compose services"
	@echo "  make down             Stop docker-compose services"
	@echo "  make logs             Tail compose logs"
	@echo "  make dev              Run uvicorn locally (requires .venv activated)"
	@echo "  make test             Run pytest"
	@echo "  make lint             Run ruff + black check"
	@echo "  make format           Run black and isort"
	@echo "  make precommit-install Install pre-commit hooks"
	@echo "  make db-migrate       Run alembic upgrade head inside docker web container"
	@echo "  make docker-run       Open shell in web container"

build:
	docker compose build

up:
	docker compose up -d --remove-orphans

down:
	docker compose down

logs:
	docker compose logs -f

restart: down up

dev:
	# Run locally (requires venv and dependencies installed)
	uvicorn app.main:app --reload --host ${FASTAPI_HOST:-127.0.0.1} --port ${FASTAPI_PORT:-8000}

test:
	pytest -q

lint:
	ruff check .
	black --check .

format:
	isort .
	black .

precommit-install:
	pre-commit install

db-migrate:
	# Run alembic migrations inside the web container; adjust path if needed
	docker compose run --rm web alembic upgrade head

docker-run:
	docker compose run --rm web bash
