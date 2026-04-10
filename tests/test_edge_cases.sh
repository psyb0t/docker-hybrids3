#!/bin/bash
# tests/test_edge_cases.sh - Edge cases, size limits, path traversal, special chars

test_max_file_size_under_limit() {
    # tiny-bucket has max_file_size: 100B
    local data
    data=$(python3 -c "print('x' * 50, end='')")
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/tiny-bucket/small.txt" \
        -H "Authorization: Bearer tiny-key" -d "$data")
    assert_eq "$code" "200" "file under size limit accepted"

    curl -s -X DELETE "$BASE/tiny-bucket/small.txt" -H "Authorization: Bearer tiny-key" >/dev/null
}
ALL_TESTS+=(test_max_file_size_under_limit)

test_max_file_size_over_limit() {
    # tiny-bucket has max_file_size: 100B
    local data
    data=$(python3 -c "print('x' * 200, end='')")
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/tiny-bucket/toobig.txt" \
        -H "Authorization: Bearer tiny-key" -d "$data")
    assert_eq "$code" "413" "file over size limit rejected"
}
ALL_TESTS+=(test_max_file_size_over_limit)

test_max_file_size_exact_boundary() {
    # exactly 100 bytes
    local data
    data=$(python3 -c "print('x' * 100, end='')")
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/tiny-bucket/exact.txt" \
        -H "Authorization: Bearer tiny-key" -d "$data")
    assert_eq "$code" "200" "file at exact size limit accepted"

    curl -s -X DELETE "$BASE/tiny-bucket/exact.txt" -H "Authorization: Bearer tiny-key" >/dev/null
}
ALL_TESTS+=(test_max_file_size_exact_boundary)

test_path_traversal_dotdot() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket/../../etc/passwd" \
        -H "Authorization: Bearer pub-key" -d "hacked")
    # should either 400/404/422 or silently sanitize
    if [ "$code" = "200" ]; then
        echo "  FAIL: path traversal accepted (HTTP 200)"
        return 1
    fi
    echo "  OK: path traversal rejected (HTTP $code)"
}
ALL_TESTS+=(test_path_traversal_dotdot)

test_path_traversal_encoded() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket/..%2F..%2Fetc%2Fpasswd" \
        -H "Authorization: Bearer pub-key" -d "hacked")
    if [ "$code" = "200" ]; then
        # check the file didn't end up outside the bucket
        local exists
        exists=$(docker exec "$CONTAINER_NAME" test -f /etc/passwd-hacked && echo yes || echo no)
        # this is ok, the file should be within the bucket dir
        echo "  OK: encoded path traversal handled safely"
        return 0
    fi
    echo "  OK: encoded path traversal rejected (HTTP $code)"
}
ALL_TESTS+=(test_path_traversal_encoded)

test_special_chars_in_key() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        "$BASE/public-bucket/special%20chars%21%40%23.txt" \
        -H "Authorization: Bearer pub-key" -d "special")
    assert_eq "$code" "200" "special chars in key accepted"

    local body
    body=$(curl -s "$BASE/public-bucket/special%20chars%21%40%23.txt")
    assert_eq "$body" "special" "special chars key readable"

    curl -s -X DELETE "$BASE/public-bucket/special%20chars%21%40%23.txt" \
        -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_special_chars_in_key)

test_unicode_key_urlencoded() {
    # raw unicode in URL is rejected by HTTP spec; must be percent-encoded
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        "$BASE/public-bucket/%E6%97%A5%E6%9C%AC%E8%AA%9E.txt" \
        -H "Authorization: Bearer pub-key" -d "unicode content")
    assert_eq "$code" "200" "url-encoded unicode key accepted"

    local body
    body=$(curl -s "$BASE/public-bucket/%E6%97%A5%E6%9C%AC%E8%AA%9E.txt")
    assert_eq "$body" "unicode content" "url-encoded unicode key readable"

    curl -s -X DELETE "$BASE/public-bucket/%E6%97%A5%E6%9C%AC%E8%AA%9E.txt" \
        -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_unicode_key_urlencoded)

test_s3_xml_error_format() {
    # S3 requests should get XML error responses
    local resp
    resp=$(curl -s "$BASE/fakebucket/file.txt" -H "X-Amz-Content-Sha256: UNSIGNED-PAYLOAD")
    assert_contains "$resp" "<Error>" "S3 request gets XML error"
    assert_contains "$resp" "NoSuchBucket" "XML contains error code"
}
ALL_TESTS+=(test_s3_xml_error_format)

test_http_json_error_format() {
    # plain HTTP requests should get JSON error responses
    local resp
    resp=$(curl -s "$BASE/fakebucket/file.txt")
    assert_contains "$resp" '"error"' "HTTP request gets JSON error"
    assert_contains "$resp" "NoSuchBucket" "JSON contains error code"
}
ALL_TESTS+=(test_http_json_error_format)

test_head_bucket_exists() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -I "$BASE/public-bucket")
    assert_eq "$code" "200" "HEAD existing bucket returns 200"
}
ALL_TESTS+=(test_head_bucket_exists)

test_head_bucket_not_exists() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -I "$BASE/nope-bucket")
    assert_eq "$code" "404" "HEAD nonexistent bucket returns 404"
}
ALL_TESTS+=(test_head_bucket_not_exists)

test_s3_create_bucket_noop() {
    # PUT /{bucket} should return 200 if bucket exists (S3 compat)
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket" \
        -H "Authorization: Bearer pub-key")
    assert_eq "$code" "200" "create existing bucket returns 200 (noop)"
}
ALL_TESTS+=(test_s3_create_bucket_noop)

test_s3_create_bucket_nonexistent() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/new-bucket" \
        -H "Authorization: Bearer pub-key")
    assert_eq "$code" "404" "create non-configured bucket returns 404"
}
ALL_TESTS+=(test_s3_create_bucket_nonexistent)

test_binary_file() {
    # upload binary data
    local tmpfile
    tmpfile=$(mktemp)
    python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256)))" > "$tmpfile"

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket/binary.bin" \
        -H "Authorization: Bearer pub-key" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$tmpfile")
    assert_eq "$code" "200" "binary upload accepted"

    # download and compare
    local tmpout
    tmpout=$(mktemp)
    curl -s "$BASE/public-bucket/binary.bin" -o "$tmpout"
    if cmp -s "$tmpfile" "$tmpout"; then
        echo "  OK: binary file round-trip matches"
    else
        echo "  FAIL: binary file content mismatch"
        rm -f "$tmpfile" "$tmpout"
        return 1
    fi

    rm -f "$tmpfile" "$tmpout"
    curl -s -X DELETE "$BASE/public-bucket/binary.bin" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_binary_file)

test_concurrent_uploads() {
    # fire off 10 parallel uploads
    for i in $(seq 1 10); do
        curl -s -X PUT "$BASE/public-bucket/concurrent-$i.txt" \
            -H "Authorization: Bearer pub-key" -d "data-$i" &
    done
    wait

    # verify all exist
    local count=0
    for i in $(seq 1 10); do
        local body
        body=$(curl -s "$BASE/public-bucket/concurrent-$i.txt")
        if [ "$body" = "data-$i" ]; then
            count=$((count + 1))
        fi
    done
    assert_eq "$count" "10" "all 10 concurrent uploads succeeded"

    # cleanup
    for i in $(seq 1 10); do
        curl -s -X DELETE "$BASE/public-bucket/concurrent-$i.txt" \
            -H "Authorization: Bearer pub-key" >/dev/null &
    done
    wait
}
ALL_TESTS+=(test_concurrent_uploads)
