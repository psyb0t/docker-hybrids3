#!/bin/bash
# tests/test_http.sh - Plain HTTP interface tests

test_health() {
    local resp
    resp=$(curl -s "$BASE/health")
    assert_eq "$(echo "$resp" | json_get '["status"]')" "ok" "health endpoint"
}
ALL_TESTS+=(test_health)

test_list_buckets_http() {
    local resp
    resp=$(curl -s "$BASE/" -H "Authorization: Bearer test-master-key")
    assert_contains "$resp" "public-bucket" "list includes public-bucket"
    assert_contains "$resp" "private-bucket" "list includes private-bucket"
    assert_contains "$resp" "expiring-bucket" "list includes expiring-bucket"
    assert_contains "$resp" "tiny-bucket" "list includes tiny-bucket"
}
ALL_TESTS+=(test_list_buckets_http)

test_list_buckets_no_auth() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/")
    assert_eq "$code" "403" "list buckets without auth blocked"
}
ALL_TESTS+=(test_list_buckets_no_auth)

test_list_buckets_bucket_key() {
    # bucket key should return only that bucket
    local resp
    resp=$(curl -s "$BASE/" -H "Authorization: Bearer pub-key")
    assert_contains "$resp" "public-bucket" "bucket key lists own bucket"

    # should NOT contain other buckets
    if echo "$resp" | grep -qF "private-bucket"; then
        echo "  FAIL: bucket key leaked other buckets: $resp"
        return 1
    fi
    echo "  OK: bucket key does not leak other buckets"
}
ALL_TESTS+=(test_list_buckets_bucket_key)

test_list_buckets_bucket_key_private() {
    # private bucket key should list only the private bucket
    local resp
    resp=$(curl -s "$BASE/" -H "Authorization: Bearer priv-key")
    assert_contains "$resp" "private-bucket" "priv key lists own bucket"

    if echo "$resp" | grep -qF "public-bucket"; then
        echo "  FAIL: priv key leaked other buckets: $resp"
        return 1
    fi
    echo "  OK: priv key does not leak other buckets"
}
ALL_TESTS+=(test_list_buckets_bucket_key_private)

test_upload_download_public() {
    # upload with bearer token
    local resp
    resp=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket/hello.txt" \
        -H "Authorization: Bearer pub-key" \
        -H "Content-Type: text/plain" \
        -d "hello world")
    assert_eq "$resp" "200" "upload to public bucket"

    # download without auth (public)
    local body
    body=$(curl -s "$BASE/public-bucket/hello.txt")
    assert_eq "$body" "hello world" "download from public bucket (no auth)"

    # cleanup
    curl -s -X DELETE "$BASE/public-bucket/hello.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_upload_download_public)

test_head_object() {
    curl -s -X PUT "$BASE/public-bucket/headtest.txt" \
        -H "Authorization: Bearer pub-key" -H "Content-Type: text/plain" -d "headme" >/dev/null

    local code content_type
    code=$(curl -s -o /dev/null -w "%{http_code}" -I "$BASE/public-bucket/headtest.txt")
    assert_eq "$code" "200" "HEAD returns 200"

    content_type=$(curl -s -I "$BASE/public-bucket/headtest.txt" | grep -i "^content-type:" | tr -d '\r' | awk '{print $2}' | tr -d ';')
    assert_contains "$content_type" "text/plain" "HEAD returns correct content-type"

    curl -s -X DELETE "$BASE/public-bucket/headtest.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_head_object)

test_delete_object() {
    curl -s -X PUT "$BASE/public-bucket/deleteme.txt" \
        -H "Authorization: Bearer pub-key" -d "gone soon" >/dev/null

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/public-bucket/deleteme.txt" \
        -H "Authorization: Bearer pub-key")
    assert_eq "$code" "204" "delete returns 204"

    # verify gone
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/public-bucket/deleteme.txt")
    assert_eq "$code" "404" "deleted object returns 404"
}
ALL_TESTS+=(test_delete_object)

test_delete_nonexistent() {
    # S3 compat: delete nonexistent returns 204
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/public-bucket/does-not-exist.txt" \
        -H "Authorization: Bearer pub-key")
    assert_eq "$code" "204" "delete nonexistent returns 204 (S3 compat)"
}
ALL_TESTS+=(test_delete_nonexistent)

test_get_nonexistent() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/public-bucket/nope.txt")
    assert_eq "$code" "404" "GET nonexistent returns 404"
}
ALL_TESTS+=(test_get_nonexistent)

test_nonexistent_bucket() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/fakebucket/file.txt")
    assert_eq "$code" "404" "nonexistent bucket returns 404"
}
ALL_TESTS+=(test_nonexistent_bucket)

test_list_objects() {
    curl -s -X PUT "$BASE/public-bucket/list1.txt" -H "Authorization: Bearer pub-key" -d "a" >/dev/null
    curl -s -X PUT "$BASE/public-bucket/list2.txt" -H "Authorization: Bearer pub-key" -d "b" >/dev/null

    local resp
    resp=$(curl -s "$BASE/public-bucket")
    assert_contains "$resp" "list1.txt" "list contains list1.txt"
    assert_contains "$resp" "list2.txt" "list contains list2.txt"

    curl -s -X DELETE "$BASE/public-bucket/list1.txt" -H "Authorization: Bearer pub-key" >/dev/null
    curl -s -X DELETE "$BASE/public-bucket/list2.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_list_objects)

test_nested_keys() {
    curl -s -X PUT "$BASE/public-bucket/a/b/c/deep.txt" \
        -H "Authorization: Bearer pub-key" -d "deep file" >/dev/null

    local body
    body=$(curl -s "$BASE/public-bucket/a/b/c/deep.txt")
    assert_eq "$body" "deep file" "nested key read"

    # list with prefix
    local resp
    resp=$(curl -s "$BASE/public-bucket?prefix=a/b/")
    assert_contains "$resp" "a/b/c/deep.txt" "list with prefix finds nested key"

    curl -s -X DELETE "$BASE/public-bucket/a/b/c/deep.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_nested_keys)

test_overwrite_object() {
    curl -s -X PUT "$BASE/public-bucket/overwrite.txt" \
        -H "Authorization: Bearer pub-key" -d "version1" >/dev/null

    curl -s -X PUT "$BASE/public-bucket/overwrite.txt" \
        -H "Authorization: Bearer pub-key" -d "version2" >/dev/null

    local body
    body=$(curl -s "$BASE/public-bucket/overwrite.txt")
    assert_eq "$body" "version2" "overwrite replaces content"

    curl -s -X DELETE "$BASE/public-bucket/overwrite.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_overwrite_object)

test_empty_file() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/public-bucket/empty.txt" \
        -H "Authorization: Bearer pub-key" -H "Content-Length: 0")
    assert_eq "$code" "200" "upload empty file"

    local body
    body=$(curl -s "$BASE/public-bucket/empty.txt")
    assert_eq "$body" "" "download empty file"

    curl -s -X DELETE "$BASE/public-bucket/empty.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_empty_file)

test_content_type_preserved() {
    curl -s -X PUT "$BASE/public-bucket/data.json" \
        -H "Authorization: Bearer pub-key" \
        -H "Content-Type: application/json" \
        -d '{"foo": "bar"}' >/dev/null

    local ct
    ct=$(curl -s -I "$BASE/public-bucket/data.json" | grep -i "^content-type:" | tr -d '\r' | awk '{print $2}')
    assert_contains "$ct" "application/json" "explicit content-type preserved"

    curl -s -X DELETE "$BASE/public-bucket/data.json" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_content_type_preserved)

test_mimetype_auto_detect_json() {
    # upload JSON without explicit Content-Type
    curl -s -X PUT "$BASE/public-bucket/auto.json" \
        -H "Authorization: Bearer pub-key" \
        -d '{"hello": "world"}' >/dev/null

    local ct
    ct=$(curl -s -I "$BASE/public-bucket/auto.json" | grep -i "^content-type:" | tr -d '\r' | awk '{print $2}')
    assert_contains "$ct" "application/json" "auto-detected JSON"

    curl -s -X DELETE "$BASE/public-bucket/auto.json" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_mimetype_auto_detect_json)

test_mimetype_auto_detect_html() {
    curl -s -X PUT "$BASE/public-bucket/page.html" \
        -H "Authorization: Bearer pub-key" \
        -d '<html><body>hi</body></html>' >/dev/null

    local ct
    ct=$(curl -s -I "$BASE/public-bucket/page.html" | grep -i "^content-type:" | tr -d '\r' | awk '{print $2}')
    assert_contains "$ct" "text/html" "auto-detected HTML"

    curl -s -X DELETE "$BASE/public-bucket/page.html" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_mimetype_auto_detect_html)

test_mimetype_auto_detect_png() {
    # upload PNG magic bytes without Content-Type header
    local tmpfile
    tmpfile=$(mktemp)
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR' > "$tmpfile"

    curl -s -X PUT "$BASE/public-bucket/img.png" \
        -H "Authorization: Bearer pub-key" \
        --data-binary "@$tmpfile" >/dev/null

    local ct
    ct=$(curl -s -I "$BASE/public-bucket/img.png" | grep -i "^content-type:" | tr -d '\r' | awk '{print $2}')
    assert_contains "$ct" "image/png" "auto-detected PNG"

    rm -f "$tmpfile"
    curl -s -X DELETE "$BASE/public-bucket/img.png" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_mimetype_auto_detect_png)

test_mimetype_auto_detect_by_extension() {
    # plain text content but .css extension — should detect as CSS
    curl -s -X PUT "$BASE/public-bucket/style.css" \
        -H "Authorization: Bearer pub-key" \
        -d 'body { color: red; }' >/dev/null

    local ct
    ct=$(curl -s -I "$BASE/public-bucket/style.css" | grep -i "^content-type:" | tr -d '\r' | awk '{print $2}')
    assert_contains "$ct" "text/css" "auto-detected CSS by extension"

    curl -s -X DELETE "$BASE/public-bucket/style.css" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_mimetype_auto_detect_by_extension)

test_etag_returned() {
    local headers
    headers=$(curl -s -D - -o /dev/null -X PUT "$BASE/public-bucket/etag.txt" \
        -H "Authorization: Bearer pub-key" -d "etag test")
    assert_contains "$headers" "etag" "PUT returns ETag header"

    local get_headers
    get_headers=$(curl -s -D - -o /dev/null "$BASE/public-bucket/etag.txt")
    assert_contains "$get_headers" "etag" "GET returns ETag header"

    curl -s -X DELETE "$BASE/public-bucket/etag.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_etag_returned)
