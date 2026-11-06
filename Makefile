# Common tasks. Run `make` to list them.
# Everything except `test` needs Docker only; the linters run in their
# official images, pinned to the same versions CI uses.

IMAGE ?= devops-screening-task:local

GOLANGCI_LINT_IMAGE := golangci/golangci-lint:v2.15.0
HADOLINT_IMAGE      := hadolint/hadolint:v2.15.1
SHELLCHECK_IMAGE    := koalaman/shellcheck:v0.11.0

.DEFAULT_GOAL := help
.PHONY: help up down logs build test lint smoke health clean

help: ## List available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-z]+:.*## / { printf "  %-7s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

up: ## Build and start the app on http://localhost:8080
	docker compose up --build --detach

down: ## Stop and remove the app
	docker compose down

logs: ## Follow the app's logs
	docker compose logs --follow

build: ## Build the Docker image
	docker build --tag $(IMAGE) .

test: ## Run the Go unit tests (needs Go 1.27+)
	cd app && go test -race -cover ./...

lint: ## Lint Go code, the Dockerfile and shell scripts
	docker run --rm -v "$(CURDIR)/app:/app" -w /app $(GOLANGCI_LINT_IMAGE) golangci-lint run
	docker run --rm -i $(HADOLINT_IMAGE) < Dockerfile
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt $(SHELLCHECK_IMAGE) scripts/system_health.sh scripts/smoke_test.sh

smoke: build ## Build the image, run it and check the response
	./scripts/smoke_test.sh $(IMAGE)

health: ## Run the system health check once
	./scripts/system_health.sh

clean: ## Remove containers, the local image and the health log
	docker compose down --rmi local
	rm -f health_log.txt
