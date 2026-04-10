#!/bin/bash
# tests/test_auth.sh - Auth scenarios: public, private, master key, wrong key, no key

# ── Public bucket ────────────────────────────────────────────────────────────

test_public_read_no_auth() {
    curl -s -X PUT "$BASE/public-bucket/auth-test.txt" \
        -H "Authorization: Bearer pub-key" -d "public data" >/dev/null

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/public-bucket/auth-test.txt")
    assert_eq "$code" "200" "public bucket: GET without auth"

    curl -s -X DELETE "$BASE/public-bucket/auth-test.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_public_read_no_auth)

test_public_write_no_auth() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket/noauth.txt" -d "nope")
    assert_eq "$code" "404" "public bucket: PUT without auth blocked"
}
ALL_TESTS+=(test_public_write_no_auth)

test_public_write_wrong_key() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket/wrongkey.txt" \
        -H "Authorization: Bearer wrong-key" -d "nope")
    assert_eq "$code" "404" "public bucket: PUT with wrong key blocked"
}
ALL_TESTS+=(test_public_write_wrong_key)

test_public_write_correct_key() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket/goodkey.txt" \
        -H "Authorization: Bearer pub-key" -d "yep")
    assert_eq "$code" "200" "public bucket: PUT with correct key"

    curl -s -X DELETE "$BASE/public-bucket/goodkey.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_public_write_correct_key)

test_public_write_master_key() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket/masterkey.txt" \
        -H "Authorization: Bearer test-master-key" -d "via master")
    assert_eq "$code" "200" "public bucket: PUT with master key"

    curl -s -X DELETE "$BASE/public-bucket/masterkey.txt" -H "Authorization: Bearer test-master-key" >/dev/null
}
ALL_TESTS+=(test_public_write_master_key)

test_public_delete_no_auth() {
    curl -s -X PUT "$BASE/public-bucket/nodelete.txt" \
        -H "Authorization: Bearer pub-key" -d "stay" >/dev/null

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/public-bucket/nodelete.txt")
    assert_eq "$code" "404" "public bucket: DELETE without auth blocked"

    curl -s -X DELETE "$BASE/public-bucket/nodelete.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_public_delete_no_auth)

# ── Private bucket ───────────────────────────────────────────────────────────

test_private_read_no_auth() {
    curl -s -X PUT "$BASE/private-bucket/secret.txt" \
        -H "Authorization: Bearer priv-key" -d "secret" >/dev/null

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/private-bucket/secret.txt")
    assert_eq "$code" "404" "private bucket: GET without auth blocked"

    curl -s -X DELETE "$BASE/private-bucket/secret.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_private_read_no_auth)

test_private_read_wrong_key() {
    curl -s -X PUT "$BASE/private-bucket/secret2.txt" \
        -H "Authorization: Bearer priv-key" -d "secret" >/dev/null

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/private-bucket/secret2.txt" \
        -H "Authorization: Bearer wrong-key")
    assert_eq "$code" "404" "private bucket: GET with wrong key blocked"

    curl -s -X DELETE "$BASE/private-bucket/secret2.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_private_read_wrong_key)

test_private_read_correct_key() {
    curl -s -X PUT "$BASE/private-bucket/secret3.txt" \
        -H "Authorization: Bearer priv-key" -d "the secret" >/dev/null

    local body
    body=$(curl -s "$BASE/private-bucket/secret3.txt" -H "Authorization: Bearer priv-key")
    assert_eq "$body" "the secret" "private bucket: GET with correct key"

    curl -s -X DELETE "$BASE/private-bucket/secret3.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_private_read_correct_key)

test_private_read_master_key() {
    curl -s -X PUT "$BASE/private-bucket/secret4.txt" \
        -H "Authorization: Bearer priv-key" -d "the secret" >/dev/null

    local body
    body=$(curl -s "$BASE/private-bucket/secret4.txt" -H "Authorization: Bearer test-master-key")
    assert_eq "$body" "the secret" "private bucket: GET with master key"

    curl -s -X DELETE "$BASE/private-bucket/secret4.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_private_read_master_key)

test_private_write_no_auth() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/private-bucket/nope.txt" -d "nope")
    assert_eq "$code" "404" "private bucket: PUT without auth blocked"
}
ALL_TESTS+=(test_private_write_no_auth)

test_private_list_no_auth() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/private-bucket")
    assert_eq "$code" "404" "private bucket: LIST without auth blocked"
}
ALL_TESTS+=(test_private_list_no_auth)

test_private_list_with_key() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/private-bucket" \
        -H "Authorization: Bearer priv-key")
    assert_eq "$code" "200" "private bucket: LIST with correct key"
}
ALL_TESTS+=(test_private_list_with_key)

test_private_head_no_auth() {
    curl -s -X PUT "$BASE/private-bucket/headpriv.txt" \
        -H "Authorization: Bearer priv-key" -d "data" >/dev/null

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -I "$BASE/private-bucket/headpriv.txt")
    assert_eq "$code" "404" "private bucket: HEAD without auth blocked"

    curl -s -X DELETE "$BASE/private-bucket/headpriv.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_private_head_no_auth)

# ── Cross-bucket key isolation ───────────────────────────────────────────────

test_cross_bucket_key_rejected() {
    # pub-key should NOT work on private-bucket
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/private-bucket/cross.txt" \
        -H "Authorization: Bearer pub-key" -d "nope")
    assert_eq "$code" "404" "pub-key rejected on private-bucket"
}
ALL_TESTS+=(test_cross_bucket_key_rejected)
