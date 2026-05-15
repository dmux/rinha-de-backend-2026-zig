# Rinha de Backend 2026 - Zig Implementation
# Makefile for automation

IMAGE_NAME = ghcr.io/dmux/rinha-de-backend-2026-zig
TAG = latest

.PHONY: all build push up down logs test clean help

all: build

## build: Build the Docker image (utilizes cache for preprocessing)
build:
	docker build -t $(IMAGE_NAME):$(TAG) --target runtime .

## push: Push the Docker image to GHCR
push: build
	docker push $(IMAGE_NAME):$(TAG)

## up: Start the environment using Docker Compose
up:
	docker compose up -d

## down: Stop and remove the environment
down:
	docker compose down --remove-orphans

## logs: Tail logs from all containers
logs:
	docker compose logs -f

## test: Run the official official k6 load test
test:
	./k6 run test/official_test.js

## integration-test: Run the Python proxy integration tests
integration-test:
	python3 test/proxy_integration_test.py

## clean: Remove build artifacts and stopped containers
clean:
	docker compose down -v
	rm -rf zig-out .zig-cache
	docker image prune -f

## help: Show this help message
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@sed -n 's/^##//p' Makefile | column -t -s ':' | sed -e 's/^/ /'
