#!/bin/bash
# tests/test_lock_http.sh - HTTP-level tests for lock overload and timeout responses.
# Uses lock_max_waiters=15, lock_acquire_timeout=0.5, lock_hold_timeout=2 from test config.

# Hold a write lock open by streaming a slow upload (rate-limited), fire concurrent
# requests against the same key, verify 503s come back correctly.

test_lock_overload_503() {
    # slow writer holds the write lock; fire max_waiters+2 concurrent waiters
    # at least one should get 503 overloaded
    local key="lock-overload-test.txt"

    # generate 100KB of data — enough to stream slowly past hold_timeout
    local tmp
    tmp=$(mktemp)
    dd if=/dev/urandom of="$tmp" bs=1024 count=100 2>/dev/null

    # stream upload at 20KB/s — takes ~5s, plenty of time to queue
    curl -s -X PUT "$BASE/public-bucket/$key" \
        -H "Authorization: Bearer pub-key" \
        --limit-rate 20K \
        --data-binary "@$tmp" \
        -o /dev/null &
    local slow_pid=$!

    sleep 0.3  # let the slow upload acquire the write lock

    # fire max_waiters+2 (17) concurrent GETs — queue fills at 15, extras get 503
    # acquire_timeout is 0.5s so queued ones also get 503 quickly
    local codes
    codes=$(python3 - "$BASE/public-bucket/$key" <<'EOF'
import sys, subprocess, concurrent.futures

url = sys.argv[1]

def get(_):
    r = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", url],
        capture_output=True, text=True,
    )
    return r.stdout.strip()

with concurrent.futures.ThreadPoolExecutor(max_workers=17) as ex:
    results = list(ex.map(get, range(17)))
print("\n".join(results))
EOF
)

    kill "$slow_pid" 2>/dev/null
    wait "$slow_pid" 2>/dev/null
    rm -f "$tmp"
    curl -s -X DELETE "$BASE/public-bucket/$key" \
        -H "Authorization: Bearer pub-key" -o /dev/null

    local got_503
    got_503=$(echo "$codes" | grep -c "^503$" || true)
    if [ "$got_503" -gt 0 ]; then
        echo "  OK: lock overload returns 503 ($got_503 requests rejected)"
    else
        echo "  FAIL: expected at least one 503 overload, got: $(echo "$codes" | tr '\n' ' ')"
        return 1
    fi
}
ALL_TESTS+=(test_lock_overload_503)

test_lock_acquire_timeout_503() {
    # slow writer holds the lock; single reader waits past acquire_timeout (0.5s)
    local key="lock-acqtimeout-test.txt"

    local tmp
    tmp=$(mktemp)
    dd if=/dev/urandom of="$tmp" bs=1024 count=100 2>/dev/null

    curl -s -X PUT "$BASE/public-bucket/$key" \
        -H "Authorization: Bearer pub-key" \
        --limit-rate 20K \
        --data-binary "@$tmp" \
        -o /dev/null &
    local slow_pid=$!

    sleep 0.3  # let slow upload acquire the write lock

    # single GET waits > 0.5s acquire_timeout → 503
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/public-bucket/$key")

    kill "$slow_pid" 2>/dev/null
    wait "$slow_pid" 2>/dev/null
    rm -f "$tmp"
    curl -s -X DELETE "$BASE/public-bucket/$key" \
        -H "Authorization: Bearer pub-key" -o /dev/null

    assert_eq "$code" "503" "acquire timeout returns 503"
}
ALL_TESTS+=(test_lock_acquire_timeout_503)

test_lock_hold_timeout_503() {
    # upload a file normally first so GET has something to find
    curl -s -X PUT "$BASE/public-bucket/lock-hold-test.txt" \
        -H "Authorization: Bearer pub-key" -d "hold timeout test" -o /dev/null

    # --limit-rate and --data-binary "@fifo" both fail in Docker: curl buffers
    # all data before sending (to set Content-Length), so 25 bytes arrive in
    # <1ms and the server never suspends.
    #
    # curl -T - reads stdin with chunked Transfer-Encoding — no buffering.
    # Each printf chunk is sent immediately. The server genuinely awaits between
    # chunks, letting asyncio.timeout(hold_timeout=2s) fire mid-stream → 503.
    local code
    code=$(
        ( for _ in 1 2 3 4 5; do printf 'hello'; sleep 1; done ) | \
        curl -s -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer pub-key" \
            -T - \
            "$BASE/public-bucket/lock-hold-test.txt"
    )

    curl -s -X DELETE "$BASE/public-bucket/lock-hold-test.txt" \
        -H "Authorization: Bearer pub-key" -o /dev/null

    assert_eq "$code" "503" "hold timeout returns 503"
}
ALL_TESTS+=(test_lock_hold_timeout_503)
