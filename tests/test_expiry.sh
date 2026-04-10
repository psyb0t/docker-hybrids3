#!/bin/bash
# tests/test_expiry.sh - TTL expiry tests
# expiring-bucket has ttl: 8s, cleanup_interval: 3s

test_expiry_object_exists_initially() {
    curl -s -X PUT "$BASE/expiring-bucket/expire-me.txt" \
        -H "Authorization: Bearer exp-key" -d "temporary" >/dev/null

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/expiring-bucket/expire-me.txt")
    assert_eq "$code" "200" "expiring object exists immediately after upload"
}
ALL_TESTS+=(test_expiry_object_exists_initially)

test_expiry_object_gone_after_ttl() {
    curl -s -X PUT "$BASE/expiring-bucket/expire-wait.txt" \
        -H "Authorization: Bearer exp-key" -d "going away" >/dev/null

    # verify it exists
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/expiring-bucket/expire-wait.txt")
    assert_eq "$code" "200" "object exists before TTL"

    # wait for TTL (8s) + cleanup interval (3s) + buffer
    echo "  ... waiting 14s for expiry (ttl=8s + cleanup=3s + buffer)..."
    sleep 14

    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/expiring-bucket/expire-wait.txt")
    assert_eq "$code" "404" "object gone after TTL"
}
ALL_TESTS+=(test_expiry_object_gone_after_ttl)

test_expiry_non_expiring_survives() {
    # Upload to permanent bucket (ttl: 0) - should survive the expiry wait
    curl -s -X PUT "$BASE/private-bucket/permanent.txt" \
        -H "Authorization: Bearer priv-key" -d "i stay forever" >/dev/null

    # Upload to expiring bucket
    curl -s -X PUT "$BASE/expiring-bucket/temp.txt" \
        -H "Authorization: Bearer exp-key" -d "i die" >/dev/null

    echo "  ... waiting 14s for expiry..."
    sleep 14

    # expiring should be gone
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/expiring-bucket/temp.txt")
    assert_eq "$code" "404" "expiring object is gone"

    # permanent should survive
    local body
    body=$(curl -s "$BASE/private-bucket/permanent.txt" -H "Authorization: Bearer priv-key")
    assert_eq "$body" "i stay forever" "permanent object survives"

    curl -s -X DELETE "$BASE/private-bucket/permanent.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_expiry_non_expiring_survives)

test_expiry_refresh_on_overwrite() {
    # Upload, wait a bit, overwrite, then the TTL should reset
    curl -s -X PUT "$BASE/expiring-bucket/refresh.txt" \
        -H "Authorization: Bearer exp-key" -d "original" >/dev/null

    # wait 5s (less than 8s TTL)
    sleep 5

    # overwrite - should reset the TTL
    curl -s -X PUT "$BASE/expiring-bucket/refresh.txt" \
        -H "Authorization: Bearer exp-key" -d "refreshed" >/dev/null

    # wait another 5s - total 10s from first upload but only 5s from overwrite
    sleep 5

    # should still exist (TTL was reset by overwrite)
    local body
    body=$(curl -s "$BASE/expiring-bucket/refresh.txt")
    assert_eq "$body" "refreshed" "overwrite refreshes TTL"

    # now wait for full expiry
    echo "  ... waiting 8s for final expiry..."
    sleep 8

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/expiring-bucket/refresh.txt")
    assert_eq "$code" "404" "eventually expires after TTL from last write"
}
ALL_TESTS+=(test_expiry_refresh_on_overwrite)
