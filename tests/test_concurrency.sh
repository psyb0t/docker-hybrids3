#!/bin/bash
# tests/test_concurrency.sh - Concurrency and locking tests

# Run N concurrent HTTP requests via Python threading. Returns all HTTP codes.
_concurrent() {
    local method="$1"
    local url="$2"
    local n="$3"
    shift 3
    # remaining args are extra curl flags (e.g. -H, -d)
    python3 - "$method" "$url" "$n" "$@" <<'EOF'
import sys, subprocess, concurrent.futures

method = sys.argv[1]
url    = sys.argv[2]
n      = int(sys.argv[3])
extra  = sys.argv[4:]

def req(_):
    cmd = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
           "-X", method] + extra + [url]
    return subprocess.check_output(cmd, text=True).strip()

with concurrent.futures.ThreadPoolExecutor(max_workers=n) as ex:
    codes = list(ex.map(req, range(n)))

print("\n".join(codes))
EOF
}

# ── tests ─────────────────────────────────────────────────────────────────────

test_concurrent_reads() {
    curl -s -X PUT "$BASE/public-bucket/conc-read.txt" \
        -H "Authorization: Bearer pub-key" -d "read me" >/dev/null

    local codes
    codes=$(_concurrent GET "$BASE/public-bucket/conc-read.txt" 10)

    local non200
    non200=$(echo "$codes" | grep -cv "^200$" || true)
    assert_eq "$non200" "0" "10 concurrent reads all return 200"

    curl -s -X DELETE "$BASE/public-bucket/conc-read.txt" \
        -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_concurrent_reads)

test_concurrent_writes() {
    local codes
    codes=$(_concurrent PUT "$BASE/public-bucket/conc-write.txt" 10 \
        -H "Authorization: Bearer pub-key" -d "payload")

    local non200
    non200=$(echo "$codes" | grep -cv "^200$" || true)
    assert_eq "$non200" "0" "10 concurrent writes all return 200"

    # object must still be readable and not corrupted
    local body
    body=$(curl -s "$BASE/public-bucket/conc-write.txt")
    assert_eq "$body" "payload" "object intact after concurrent writes"

    curl -s -X DELETE "$BASE/public-bucket/conc-write.txt" \
        -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_concurrent_writes)

test_concurrent_read_write_mix() {
    curl -s -X PUT "$BASE/public-bucket/conc-mix.txt" \
        -H "Authorization: Bearer pub-key" -d "initial" >/dev/null

    # 5 readers + 5 writers simultaneously via a single Python process
    local all_codes
    all_codes=$(python3 - "$BASE/public-bucket/conc-mix.txt" <<'EOF'
import sys, subprocess, concurrent.futures

url = sys.argv[1]

def do_get(_):
    r = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", url],
        capture_output=True, text=True,
    )
    return r.stdout.strip()

def do_put(_):
    r = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "-X", "PUT", url, "-H", "Authorization: Bearer pub-key", "-d", "updated"],
        capture_output=True, text=True,
    )
    return r.stdout.strip()

with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
    get_futs = [ex.submit(do_get, i) for i in range(5)]
    put_futs = [ex.submit(do_put, i) for i in range(5)]
    codes = [f.result() for f in get_futs + put_futs]

print("\n".join(codes))
EOF
)

    local errors
    errors=$(echo "$all_codes" | grep -cE "^5[0-9][0-9]$" || true)
    assert_eq "$errors" "0" "no 5xx during concurrent read+write mix"

    # object must exist and have valid content (either initial or updated)
    local body
    body=$(curl -s "$BASE/public-bucket/conc-mix.txt")
    if [ "$body" != "initial" ] && [ "$body" != "updated" ]; then
        echo "  FAIL: object corrupted after concurrent mix: '$body'"
        return 1
    fi
    echo "  OK: object content valid after concurrent mix"

    curl -s -X DELETE "$BASE/public-bucket/conc-mix.txt" \
        -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_concurrent_read_write_mix)

test_concurrent_writes_private() {
    local codes
    codes=$(_concurrent PUT "$BASE/private-bucket/conc-priv.txt" 8 \
        -H "Authorization: Bearer priv-key" -d "priv")

    local non200
    non200=$(echo "$codes" | grep -cv "^200$" || true)
    assert_eq "$non200" "0" "8 concurrent writes to private bucket all return 200"

    curl -s -X DELETE "$BASE/private-bucket/conc-priv.txt" \
        -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_concurrent_writes_private)

test_concurrent_deletes() {
    curl -s -X PUT "$BASE/public-bucket/conc-del.txt" \
        -H "Authorization: Bearer pub-key" -d "bye" >/dev/null

    # concurrent deletes — S3 returns 204 even if object already gone
    local codes
    codes=$(_concurrent DELETE "$BASE/public-bucket/conc-del.txt" 5 \
        -H "Authorization: Bearer pub-key")

    local non204
    non204=$(echo "$codes" | grep -cv "^204$" || true)
    assert_eq "$non204" "0" "concurrent deletes all return 204"
}
ALL_TESTS+=(test_concurrent_deletes)

test_concurrent_different_keys() {
    # writes to different keys should never block each other
    python3 - "$BASE" <<'EOF'
import sys, subprocess, concurrent.futures, time

base = sys.argv[1]

def put(i):
    url = f"{base}/public-bucket/conc-diff-{i}.txt"
    r = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "-X", "PUT", url,
         "-H", "Authorization: Bearer pub-key", "-d", f"val{i}"],
        capture_output=True, text=True,
    )
    return r.stdout.strip()

start = time.monotonic()
with concurrent.futures.ThreadPoolExecutor(max_workers=20) as ex:
    codes = list(ex.map(put, range(20)))
elapsed = time.monotonic() - start

non200 = [c for c in codes if c != "200"]
if non200:
    print(f"  FAIL: got non-200: {non200}")
    sys.exit(1)
print(f"  OK: 20 concurrent writes to different keys all 200 ({elapsed:.2f}s)")
EOF
    local rc=$?
    [ $rc -eq 0 ] || return 1

    # cleanup
    for i in $(seq 0 19); do
        curl -s -X DELETE "$BASE/public-bucket/conc-diff-$i.txt" \
            -H "Authorization: Bearer pub-key" >/dev/null
    done
}
ALL_TESTS+=(test_concurrent_different_keys)
