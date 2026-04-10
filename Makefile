# Docker image configuration
IMAGE_NAME := psyb0t/hybrids3
TAG := latest
TEST_TAG := $(TAG)-test

.PHONY: all build build-test unit-test test run stop logs clean help

# Default target
all: build

# Build the main image
build:
	docker build -t $(IMAGE_NAME):$(TAG) .

# Build the test image with -test suffix
build-test:
	docker build -t $(IMAGE_NAME):$(TEST_TAG) .

# Run unit tests (no Docker required)
unit-test:
	python -m pytest tests/test_lock_unit.py -v

# Run integration tests (builds + runs Docker)
test: build-test unit-test
	./test.sh

# Run container (requires config.yaml in current dir)
run:
	docker run -d --name hybrids3 \
		-p 8080:8080 \
		-v $(PWD)/config.yaml:/config/config.yaml:ro \
		-v hybrids3-data:/data \
		$(IMAGE_NAME):$(TAG)

# Stop and remove container
stop:
	docker stop hybrids3 && docker rm hybrids3

# Tail logs
logs:
	docker logs -f hybrids3

# Clean up images
clean:
	docker rmi $(IMAGE_NAME):$(TAG) || true
	docker rmi $(IMAGE_NAME):$(TEST_TAG) || true

# Show available targets
help:
	@echo "Available targets:"
	@echo "  build      - Build the main Docker image"
	@echo "  build-test - Build the test Docker image with -test suffix"
	@echo "  unit-test  - Run Python unit tests (no Docker required)"
	@echo "  test       - Run unit tests, build test image, run integration tests"
	@echo "  run        - Run container (needs config.yaml in current dir)"
	@echo "  stop       - Stop and remove container"
	@echo "  logs       - Tail container logs"
	@echo "  clean      - Remove built images"
	@echo "  help       - Show this help message"
