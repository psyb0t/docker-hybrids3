#!/bin/bash
# tests/test_security.sh - Security-focused tests

test_nosniff_header() {
    local headers
    headers=$(curl -s -D - -o /dev/null "$BASE/health" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    assert_contains "$headers" "nosniff" "nosniff header on health"

    headers=$(curl -s -D - -o /dev/null "$BASE/public-bucket" -H "Authorization: Bearer pub-key" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    assert_contains "$headers" "nosniff" "nosniff header on list"
}
ALL_TESTS+=(test_nosniff_header)

test_cross_bucket_traversal() {
    # bucket "public-bucket" should NOT be able to read from "private-bucket"
    # via path traversal like ../private-bucket/file
    curl -s -X PUT "$BASE/private-bucket/crosstest.txt" \
        -H "Authorization: Bearer priv-key" -d "secret cross" >/dev/null

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        "$BASE/public-bucket/../private-bucket/crosstest.txt")
    if [ "$code" = "200" ]; then
        echo "  FAIL: cross-bucket traversal succeeded"
        return 1
    fi
    echo "  OK: cross-bucket traversal blocked (HTTP $code)"

    curl -s -X DELETE "$BASE/private-bucket/crosstest.txt" \
        -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_cross_bucket_traversal)

test_max_keys_invalid() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/public-bucket?max-keys=abc")
    assert_eq "$code" "400" "max-keys=abc returns 400"
}
ALL_TESTS+=(test_max_keys_invalid)

test_max_keys_negative() {
    # should clamp to 1, not return unlimited
    curl -s -X PUT "$BASE/public-bucket/mk1.txt" -H "Authorization: Bearer pub-key" -d "a" >/dev/null
    curl -s -X PUT "$BASE/public-bucket/mk2.txt" -H "Authorization: Bearer pub-key" -d "b" >/dev/null

    local resp
    resp=$(curl -s "$BASE/public-bucket?max-keys=-1")
    local count
    count=$(echo "$resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['objects']))")
    assert_eq "$count" "1" "max-keys=-1 clamped to 1"

    curl -s -X DELETE "$BASE/public-bucket/mk1.txt" -H "Authorization: Bearer pub-key" >/dev/null
    curl -s -X DELETE "$BASE/public-bucket/mk2.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_max_keys_negative)

test_presign_endpoint() {
    # public bucket presign returns plain URL (no sig needed — GET is open)
    curl -s -X PUT "$BASE/public-bucket/presign-test.txt" \
        -H "Authorization: Bearer pub-key" -d "presigned content" >/dev/null

    local resp
    resp=$(curl -s -X POST "$BASE/presign/public-bucket/presign-test.txt?expires=60" \
        -H "Authorization: Bearer pub-key")

    # expires should be null (no expiry on plain URLs)
    local expires_val
    expires_val=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['expires'])")
    assert_eq "$expires_val" "None" "public presign returns null expires"

    local url
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")

    # URL should not contain X-Amz-Signature
    if echo "$url" | grep -q "X-Amz-Signature"; then
        echo "  FAIL: public presign URL contains signature"
        return 1
    fi
    echo "  OK: public presign URL has no signature"

    # fetch via plain URL (no auth header)
    local body
    body=$(curl -s "$url")
    assert_eq "$body" "presigned content" "public presign URL works"

    curl -s -X DELETE "$BASE/public-bucket/presign-test.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_presign_endpoint)

test_presign_private_bucket() {
    curl -s -X PUT "$BASE/private-bucket/presign-priv.txt" \
        -H "Authorization: Bearer priv-key" -d "private presigned" >/dev/null

    # get presigned URL
    local resp
    resp=$(curl -s -X POST "$BASE/presign/private-bucket/presign-priv.txt?expires=60" \
        -H "Authorization: Bearer priv-key")
    local url
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")

    # fetch via presigned URL — should work without bearer auth
    local body
    body=$(curl -s "$url")
    assert_eq "$body" "private presigned" "presigned URL works for private bucket"

    # verify direct access without presigned URL is denied
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/private-bucket/presign-priv.txt")
    assert_eq "$code" "404" "direct access without auth denied"

    curl -s -X DELETE "$BASE/private-bucket/presign-priv.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_presign_private_bucket)

test_presign_expiry_enforced() {
    # expiry only applies to private bucket presigned URLs
    curl -s -X PUT "$BASE/private-bucket/presign-exp.txt" \
        -H "Authorization: Bearer priv-key" -d "expiring" >/dev/null

    # presign with 2s expiry
    local resp
    resp=$(curl -s -X POST "$BASE/presign/private-bucket/presign-exp.txt?expires=2" \
        -H "Authorization: Bearer priv-key")
    local url
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")

    # should work now
    local body
    body=$(curl -s "$url")
    assert_eq "$body" "expiring" "presigned URL works before expiry"

    # wait for expiry
    sleep 4

    # should fail
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    assert_eq "$code" "403" "presigned URL expired"

    curl -s -X DELETE "$BASE/private-bucket/presign-exp.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_presign_expiry_enforced)

test_presign_tampered_signature() {
    curl -s -X PUT "$BASE/private-bucket/presign-tamper.txt" \
        -H "Authorization: Bearer priv-key" -d "tamper test" >/dev/null

    local resp
    resp=$(curl -s -X POST "$BASE/presign/private-bucket/presign-tamper.txt?expires=60" \
        -H "Authorization: Bearer priv-key")
    local url
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")

    # tamper with the X-Amz-Signature value
    local tampered
    tampered=$(echo "$url" | sed 's/X-Amz-Signature=[a-f0-9]*/X-Amz-Signature=0000000000000000000000000000000000000000000000000000000000000000/')
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$tampered")
    assert_eq "$code" "403" "tampered signature rejected"

    curl -s -X DELETE "$BASE/private-bucket/presign-tamper.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_presign_tampered_signature)

test_presign_no_auth() {
    # presign endpoint requires auth
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/presign/public-bucket/file.txt")
    assert_eq "$code" "404" "presign without auth denied"
}
ALL_TESTS+=(test_presign_no_auth)

test_presign_put_private_bucket() {
    # generate presigned PUT URL for a private bucket
    local resp
    resp=$(curl -s -X POST "$BASE/presign/private-bucket/presign-put.txt?method=PUT&expires=60" \
        -H "Authorization: Bearer priv-key")
    local url method
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")
    method=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['method'])")
    assert_eq "$method" "PUT" "response method is PUT"

    if ! echo "$url" | grep -q "X-Amz-Signature"; then
        echo "  FAIL: private presign PUT URL missing signature"
        return 1
    fi

    # PUT via presigned URL — no bearer header needed
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$url" --data-binary "uploaded via presign PUT")
    assert_eq "$code" "200" "presigned PUT upload accepted"

    # verify via bearer GET
    local body
    body=$(curl -s "$BASE/private-bucket/presign-put.txt" -H "Authorization: Bearer priv-key")
    assert_eq "$body" "uploaded via presign PUT" "uploaded content readable"

    curl -s -X DELETE "$BASE/private-bucket/presign-put.txt" -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_presign_put_private_bucket)

test_presign_put_public_bucket_must_sign() {
    # public buckets allow anonymous READS, never anonymous WRITES.
    # PUT presign on a public bucket must still return a signed URL.
    local resp
    resp=$(curl -s -X POST "$BASE/presign/public-bucket/presign-pub-put.txt?method=PUT&expires=60" \
        -H "Authorization: Bearer pub-key")

    local url expires_val
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")
    expires_val=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['expires'])")
    assert_eq "$expires_val" "60" "public PUT presign has expiry (signed)"

    if ! echo "$url" | grep -q "X-Amz-Signature"; then
        echo "  FAIL: public PUT presign URL missing signature"
        return 1
    fi
    echo "  OK: public PUT presign URL is signed"

    # upload without bearer
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$url" --data-binary "pub put body")
    assert_eq "$code" "200" "public presigned PUT upload accepted"

    # anonymous GET should work (public bucket)
    local body
    body=$(curl -s "$BASE/public-bucket/presign-pub-put.txt")
    assert_eq "$body" "pub put body" "uploaded body readable anonymously"

    curl -s -X DELETE "$BASE/public-bucket/presign-pub-put.txt" \
        -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_presign_put_public_bucket_must_sign)

test_presign_put_tampered_signature() {
    local resp
    resp=$(curl -s -X POST "$BASE/presign/private-bucket/presign-put-tamper.txt?method=PUT&expires=60" \
        -H "Authorization: Bearer priv-key")
    local url
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")

    local tampered
    tampered=$(echo "$url" | sed 's/X-Amz-Signature=[a-f0-9]*/X-Amz-Signature=0000000000000000000000000000000000000000000000000000000000000000/')

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$tampered" --data-binary "should not land")
    assert_eq "$code" "404" "tampered presigned PUT rejected"

    # confirm nothing was written
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        "$BASE/private-bucket/presign-put-tamper.txt" -H "Authorization: Bearer priv-key")
    assert_eq "$code" "404" "no object created from tampered PUT"
}
ALL_TESTS+=(test_presign_put_tampered_signature)

test_presign_put_method_mismatch() {
    # a URL signed for PUT must not be usable for GET, and vice versa
    local resp
    resp=$(curl -s -X POST "$BASE/presign/private-bucket/presign-method-mix.txt?method=PUT&expires=60" \
        -H "Authorization: Bearer priv-key")
    local put_url
    put_url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")

    # GET against a PUT-signed URL: signature does not match
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$put_url")
    assert_eq "$code" "403" "GET against PUT-signed URL rejected"
}
ALL_TESTS+=(test_presign_put_method_mismatch)

test_presign_invalid_method() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BASE/presign/private-bucket/x.txt?method=DELETE" \
        -H "Authorization: Bearer priv-key")
    assert_eq "$code" "400" "unsupported method rejected"
}
ALL_TESTS+=(test_presign_invalid_method)

test_presign_put_expiry_enforced() {
    # generate a presigned PUT URL with a 2s expiry
    local resp
    resp=$(curl -s -X POST "$BASE/presign/private-bucket/presign-put-exp.txt?method=PUT&expires=2" \
        -H "Authorization: Bearer priv-key")
    local url
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")

    # PUT before expiry should succeed
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$url" --data-binary "in time")
    assert_eq "$code" "200" "presigned PUT works before expiry"

    # wait past the expiry window
    sleep 4

    # PUT after expiry should be rejected
    # (write path masks bucket existence on auth failure → 404, not 403)
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$url" --data-binary "too late")
    assert_eq "$code" "404" "presigned PUT after expiry rejected"

    # confirm the expired PUT did not overwrite the original body
    local body
    body=$(curl -s "$BASE/private-bucket/presign-put-exp.txt" -H "Authorization: Bearer priv-key")
    assert_eq "$body" "in time" "expired PUT did not overwrite earlier content"

    curl -s -X DELETE "$BASE/private-bucket/presign-put-exp.txt" \
        -H "Authorization: Bearer priv-key" >/dev/null
}
ALL_TESTS+=(test_presign_put_expiry_enforced)

test_request_id_header() {
    local rid
    rid=$(curl -s -D - -o /dev/null "$BASE/health" 2>/dev/null | grep -i "x-request-id:" | tr -d '\r' | awk '{print $2}')
    # request ID should be a 12-char hex string
    if [ -z "$rid" ]; then
        echo "  FAIL: no X-Request-Id header"
        return 1
    fi
    local len=${#rid}
    if [ "$len" -ne 12 ]; then
        echo "  FAIL: X-Request-Id wrong length: '$rid' ($len chars)"
        return 1
    fi
    echo "  OK: X-Request-Id present ($rid)"
}
ALL_TESTS+=(test_request_id_header)

test_request_id_in_error_response() {
    local resp
    resp=$(curl -s "$BASE/fakebucket/nope")
    local has_rid
    has_rid=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'request_id' in d else 'no')")
    assert_eq "$has_rid" "yes" "JSON error contains request_id"
}
ALL_TESTS+=(test_request_id_in_error_response)

test_request_id_in_s3_xml_error() {
    local resp
    resp=$(curl -s "$BASE/fakebucket/nope" -H "X-Amz-Content-Sha256: x")
    assert_contains "$resp" "<RequestId>" "S3 XML error contains RequestId"
}
ALL_TESTS+=(test_request_id_in_s3_xml_error)

test_like_wildcard_injection() {
    # prefix with SQL LIKE wildcards should be escaped
    curl -s -X PUT "$BASE/public-bucket/normal.txt" -H "Authorization: Bearer pub-key" -d "a" >/dev/null
    curl -s -X PUT "$BASE/public-bucket/other.txt" -H "Authorization: Bearer pub-key" -d "b" >/dev/null

    # prefix=% should NOT match everything (it's escaped)
    local resp
    resp=$(curl -s "$BASE/public-bucket?prefix=%25")
    local count
    count=$(echo "$resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['objects']))")
    assert_eq "$count" "0" "prefix=% doesn't match all objects"

    curl -s -X DELETE "$BASE/public-bucket/normal.txt" -H "Authorization: Bearer pub-key" >/dev/null
    curl -s -X DELETE "$BASE/public-bucket/other.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_like_wildcard_injection)

test_bucket_enumeration_blocked() {
    # unauthenticated request to / should be blocked
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/")
    assert_eq "$code" "403" "bucket enumeration without auth blocked"

    # wrong key should also be blocked
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/" -H "Authorization: Bearer wrong")
    assert_eq "$code" "403" "bucket enumeration with wrong key blocked"

    # master key should work and return all buckets
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/" -H "Authorization: Bearer test-master-key")
    assert_eq "$code" "200" "bucket enumeration with master key works"

    # bucket key should work but only return that bucket
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/" -H "Authorization: Bearer pub-key")
    assert_eq "$code" "200" "bucket enumeration with bucket key works"
}
ALL_TESTS+=(test_bucket_enumeration_blocked)
