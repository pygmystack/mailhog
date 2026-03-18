PHP_FPM_IMAGE ?= uselagoon/php-8.5-fpm
IMAGE_NAME ?= pygmystack/mailhog
IMAGE_TAG  ?= test
FULL_IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

.DEFAULT_GOAL := help

.PHONY: help build test test-bats test-structure test-runtime shell clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

build: ## Build the Docker image
	docker build --tag $(FULL_IMAGE) .

test: build ## Build the image and run all BATS tests (requires: brew install bats-core)
	@command -v bats >/dev/null 2>&1 || { \
		echo "Error: bats is not installed. Install with: brew install bats-core"; \
		exit 1; \
	}
	docker pull $(PHP_FPM_IMAGE)
	IMAGE_NAME=$(FULL_IMAGE) PHP_FPM_IMAGE=$(PHP_FPM_IMAGE) bats --tap tests/

test-bats: ## Run all BATS tests without rebuilding the image
	@command -v bats >/dev/null 2>&1 || { \
		echo "Error: bats is not installed. Install with: brew install bats-core"; \
		exit 1; \
	}
	docker pull $(PHP_FPM_IMAGE)
	IMAGE_NAME=$(FULL_IMAGE) PHP_FPM_IMAGE=$(PHP_FPM_IMAGE) bats --tap tests/

test-structure: ## Run image structure tests only (no running container required)
	@command -v bats >/dev/null 2>&1 || { \
		echo "Error: bats is not installed. Install with: brew install bats-core"; \
		exit 1; \
	}
	IMAGE_NAME=$(FULL_IMAGE) bats --tap tests/image_structure.bats

test-runtime: ## Run runtime and email-flow tests (starts a MailHog container)
	@command -v bats >/dev/null 2>&1 || { \
		echo "Error: bats is not installed. Install with: brew install bats-core"; \
		exit 1; \
	}
	docker pull $(PHP_FPM_IMAGE)
	IMAGE_NAME=$(FULL_IMAGE) PHP_FPM_IMAGE=$(PHP_FPM_IMAGE) bats --tap tests/runtime.bats

shell: ## Open an interactive shell inside the container
	docker run --rm -it --entrypoint sh $(FULL_IMAGE)

clean: ## Remove the local test Docker image
	docker rmi $(FULL_IMAGE) 2>/dev/null || true
