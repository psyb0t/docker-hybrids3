#!/bin/bash
# tests/common.sh - Shared helpers, setup/teardown for hybrids3 test suite.
# Sourced by test.sh; not meant to be run directly.

IMAGE_NAME="psyb0t/hybrids3"
TEST_TAG="latest-test"
CONTAINER_NAME="hybrids3-test"
INTERNAL_PORT="8080"
BASE=""
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTDATA_DIR="$WORKDIR/.testdata"

ALL_TESTS=()

# ── Helpers ──────────────────────────────────────────────────────────────────

json_get() {
    python3 -c "import sys,json; print(json.load(sys.stdin)$1)"
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local name="$3"
    if [ "$actual" != "$expected" ]; then
        echo "  FAIL: $name: expected '$expected', got '$actual'"
        return 1
    fi
    echo "  OK: $name"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local name="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo "  FAIL: $name: '$needle' not found in output"
        return 1
    fi
    echo "  OK: $name"
}

assert_http_code() {
    local method="$1"
    local url="$2"
    local expected_code="$3"
    local name="$4"
    shift 4
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$@" "$url")
    if [ "$code" != "$expected_code" ]; then
        echo "  FAIL: $name: expected HTTP $expected_code, got $code"
        return 1
    fi
    echo "  OK: $name"
}

http_put() {
    local url="$1"
    local data="$2"
    shift 2
    curl -s -X PUT "$url" -d "$data" "$@"
}

http_get() {
    curl -s "$@"
}

wait_for_api() {
    local base_url="$1"
    local max_wait="${2:-30}"
    for i in $(seq 1 "$max_wait"); do
        if curl -sf "$base_url/health" >/dev/null 2>&1; then
            return 0
        fi
        if [ "$i" -eq "$max_wait" ]; then
            return 1
        fi
        sleep 1
    done
}

# ── S3 helper (boto3 via python) ─────────────────────────────────────────────

# Run a boto3 script. Args: public_key secret_key python_code
# The variable 's3' is pre-configured as a boto3 client.
run_s3() {
    local public_key="$1"
    local secret_key="$2"
    shift 2
    python3 -c "
import boto3, json, sys
from botocore.config import Config as BotoConfig
s3 = boto3.client(
    's3',
    endpoint_url='$BASE',
    aws_access_key_id='$public_key',
    aws_secret_access_key='$secret_key',
    region_name='us-east-1',
    config=BotoConfig(signature_version='s3v4'),
)
$*
"
}

# ── Setup / Teardown ─────────────────────────────────────────────────────────

setup() {
    rm -rf "$TESTDATA_DIR" 2>/dev/null || true
    mkdir -p "$TESTDATA_DIR"

    echo "Building test image..."
    docker build -t "$IMAGE_NAME:$TEST_TAG" "$WORKDIR" >/dev/null 2>&1

    # Write test config
    cat > "$TESTDATA_DIR/config.yaml" <<'YAML'
master_key: "test-master-key"
master_public_key: "test-master-pub"
cleanup_interval: 3

lock_acquire_timeout: 0.5
lock_hold_timeout: 2
lock_max_waiters: 15

buckets:
  public-bucket:
    public: true
    key: "pub-key"
    public_key: "pub-access-id"
    ttl: 24h
    max_file_size: 1MB

  private-bucket:
    public: false
    key: "priv-key"
    public_key: "priv-access-id"
    ttl: 0
    max_file_size: 1MB

  expiring-bucket:
    public: true
    key: "exp-key"
    public_key: "exp-access-id"
    ttl: 8s
    max_file_size: 1MB

  tiny-bucket:
    public: true
    key: "tiny-key"
    public_key: "tiny-access-id"
    ttl: 0
    max_file_size: 100B
YAML

    echo "Starting test container..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER_NAME" \
        -v "$TESTDATA_DIR/config.yaml:/config/config.yaml:ro" \
        "$IMAGE_NAME:$TEST_TAG" >/dev/null

    local container_ip
    container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")
    BASE="http://${container_ip}:${INTERNAL_PORT}"

    echo "Waiting for API at $BASE..."
    if ! wait_for_api "$BASE" 30; then
        echo "FAIL: API did not start"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -20
        exit 1
    fi
    echo "API ready"
}

test_setup() {
    : # no per-test setup needed
}

test_teardown() {
    : # no per-test teardown needed
}

cleanup() {
    echo "Cleaning up..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rmi "$IMAGE_NAME:$TEST_TAG" 2>/dev/null || true
    rm -rf "$TESTDATA_DIR" 2>/dev/null || true
}

usage() {
    echo "Usage: $0 [test_name ...]"
    echo ""
    echo "Run with no args to run all tests."
    echo "Run with test names to run specific tests."
    echo ""
    echo "Available tests:"
    for t in "${ALL_TESTS[@]}"; do
        echo "  $t"
    done
}
