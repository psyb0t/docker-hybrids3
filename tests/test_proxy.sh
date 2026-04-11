#!/bin/bash
# tests/test_proxy.sh - Reverse proxy path prefix tests
#
# Spins up a SECOND hybrids3 container with path_prefix: /storage, plus
# nginx in front.  Verifies S3 SigV4, bearer, presigned URLs all work
# through the proxy with path prefix.

PROXY_CONTAINER="hybrids3-test-nginx"
PREFIX_CONTAINER="hybrids3-test-prefix"
PROXY_BASE=""

_proxy_setup() {
    # start a second hybrids3 with path_prefix: /storage
    cat > "$TESTDATA_DIR/config-prefix.yaml" <<'YAML'
master_key: "test-master-key"
master_public_key: "test-master-pub"
cleanup_interval: 3
path_prefix: /storage

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
YAML

    docker rm -f "$PREFIX_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$PREFIX_CONTAINER" \
        -v "$TESTDATA_DIR/config-prefix.yaml:/config/config.yaml:ro" \
        "$IMAGE_NAME:$TEST_TAG" >/dev/null

    local backend_ip
    backend_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PREFIX_CONTAINER")

    # wait for backend
    for _ in $(seq 1 15); do
        if curl -sf "http://${backend_ip}:8080/storage/health" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    # nginx just forwards /storage/... as-is — no stripping
    cat > "$TESTDATA_DIR/nginx.conf" <<EOF
events {}
http {
    server {
        listen 80;
        location /storage {
            proxy_pass http://${backend_ip}:8080;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF

    docker rm -f "$PROXY_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$PROXY_CONTAINER" \
        -v "$TESTDATA_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
        nginx:alpine >/dev/null 2>&1

    local proxy_ip
    proxy_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PROXY_CONTAINER")
    PROXY_BASE="http://${proxy_ip}/storage"

    # wait for nginx
    for _ in $(seq 1 10); do
        if curl -sf "${PROXY_BASE}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    echo "  FAIL: proxy stack did not start"
    docker logs "$PREFIX_CONTAINER" 2>&1 | tail -5
    docker logs "$PROXY_CONTAINER" 2>&1 | tail -5
    return 1
}

_proxy_teardown() {
    docker rm -f "$PROXY_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$PREFIX_CONTAINER" >/dev/null 2>&1 || true
}

# boto3 helper pointed at the proxy (endpoint_url includes /storage)
_run_s3_proxy() {
    local public_key="$1"
    local secret_key="$2"
    shift 2
    python3 -c "
import boto3, json, sys
from botocore.config import Config as BotoConfig
s3 = boto3.client(
    's3',
    endpoint_url='$PROXY_BASE',
    aws_access_key_id='$public_key',
    aws_secret_access_key='$secret_key',
    region_name='us-east-1',
    config=BotoConfig(signature_version='s3v4'),
)
$*
"
}

# ── Tests ───────────────────────────────────────────────────────────────────

test_proxy_health() {
    _proxy_setup || return 1

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$PROXY_BASE/health")
    assert_eq "$code" "200" "health through proxy"

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_health)

test_proxy_bearer_put_get() {
    _proxy_setup || return 1

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$PROXY_BASE/public-bucket/proxy-test.txt" \
        -H "Authorization: Bearer pub-key" -d "hello via proxy")
    assert_eq "$code" "200" "bearer PUT through proxy" || { _proxy_teardown; return 1; }

    local body
    body=$(curl -s "$PROXY_BASE/public-bucket/proxy-test.txt")
    assert_eq "$body" "hello via proxy" "public GET through proxy" || { _proxy_teardown; return 1; }

    curl -s -X DELETE "$PROXY_BASE/public-bucket/proxy-test.txt" \
        -H "Authorization: Bearer pub-key" >/dev/null

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_bearer_put_get)

test_proxy_s3_put_get() {
    _proxy_setup || return 1

    _run_s3_proxy "pub-access-id" "pub-key" "
s3.put_object(Bucket='public-bucket', Key='proxy-s3.txt', Body=b's3 via proxy', ContentType='text/plain')
resp = s3.get_object(Bucket='public-bucket', Key='proxy-s3.txt')
body = resp['Body'].read()
assert body == b's3 via proxy', f'body mismatch: {body}'
print('ok')
s3.delete_object(Bucket='public-bucket', Key='proxy-s3.txt')
" || { echo "  FAIL: s3 put/get through proxy"; _proxy_teardown; return 1; }
    echo "  OK: s3 put/get through proxy"

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_s3_put_get)

test_proxy_s3_private_bucket() {
    _proxy_setup || return 1

    _run_s3_proxy "priv-access-id" "priv-key" "
s3.put_object(Bucket='private-bucket', Key='proxy-priv.txt', Body=b'secret via proxy')
resp = s3.get_object(Bucket='private-bucket', Key='proxy-priv.txt')
body = resp['Body'].read()
assert body == b'secret via proxy', f'body: {body}'
print('ok')
s3.delete_object(Bucket='private-bucket', Key='proxy-priv.txt')
" || { echo "  FAIL: s3 private bucket through proxy"; _proxy_teardown; return 1; }
    echo "  OK: s3 private bucket through proxy"

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_s3_private_bucket)

test_proxy_s3_list_buckets() {
    _proxy_setup || return 1

    _run_s3_proxy "test-master-pub" "test-master-key" "
resp = s3.list_buckets()
names = [b['Name'] for b in resp['Buckets']]
assert 'public-bucket' in names, f'buckets: {names}'
assert 'private-bucket' in names, f'buckets: {names}'
print('ok')
" || { echo "  FAIL: s3 list_buckets through proxy"; _proxy_teardown; return 1; }
    echo "  OK: s3 list_buckets through proxy"

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_s3_list_buckets)

test_proxy_s3_head_delete() {
    _proxy_setup || return 1

    _run_s3_proxy "pub-access-id" "pub-key" "
s3.put_object(Bucket='public-bucket', Key='proxy-head.txt', Body=b'12345')
head = s3.head_object(Bucket='public-bucket', Key='proxy-head.txt')
assert head['ContentLength'] == 5, f'size: {head[\"ContentLength\"]}'
s3.delete_object(Bucket='public-bucket', Key='proxy-head.txt')
try:
    s3.head_object(Bucket='public-bucket', Key='proxy-head.txt')
    raise AssertionError('should be gone')
except s3.exceptions.ClientError as e:
    assert e.response['Error']['Code'] == '404', f'unexpected: {e}'
print('ok')
" || { echo "  FAIL: s3 head/delete through proxy"; _proxy_teardown; return 1; }
    echo "  OK: s3 head/delete through proxy"

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_s3_head_delete)

test_proxy_s3_cross_bucket_rejected() {
    # uploads key must NOT work on private-bucket through proxy
    _proxy_setup || return 1

    _run_s3_proxy "pub-access-id" "pub-key" "
try:
    s3.put_object(Bucket='private-bucket', Key='cross.txt', Body=b'nope')
    raise AssertionError('should be denied')
except s3.exceptions.ClientError as e:
    code = e.response['Error']['Code']
    assert code in ('404', 'NoSuchBucket'), f'unexpected: {code}'
print('ok')
" || { echo "  FAIL: cross-bucket rejected through proxy"; _proxy_teardown; return 1; }
    echo "  OK: cross-bucket key rejected through proxy"

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_s3_cross_bucket_rejected)

test_proxy_s3_presigned_url() {
    # boto3 presigned URL generated through proxy endpoint → fetch through proxy
    _proxy_setup || return 1

    _run_s3_proxy "priv-access-id" "priv-key" "
import urllib.request
s3.put_object(Bucket='private-bucket', Key='proxy-presign.txt', Body=b'presigned via proxy')
url = s3.generate_presigned_url('get_object', Params={'Bucket': 'private-bucket', 'Key': 'proxy-presign.txt'}, ExpiresIn=60)
# URL should go through the proxy path
assert '/storage/' in url, f'presigned URL missing /storage/ prefix: {url}'
resp = urllib.request.urlopen(url)
body = resp.read()
assert body == b'presigned via proxy', f'body: {body}'
print('ok')
s3.delete_object(Bucket='private-bucket', Key='proxy-presign.txt')
" || { echo "  FAIL: s3 presigned URL through proxy"; _proxy_teardown; return 1; }
    echo "  OK: s3 presigned URL through proxy"

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_s3_presigned_url)

test_proxy_http_presign() {
    # HTTP presign endpoint through proxy — generated URL should include /storage/ prefix
    _proxy_setup || return 1

    curl -s -X PUT "$PROXY_BASE/private-bucket/proxy-httpps.txt" \
        -H "Authorization: Bearer priv-key" -d "presign http" >/dev/null

    local resp
    resp=$(curl -s -X POST "$PROXY_BASE/presign/private-bucket/proxy-httpps.txt?expires=60" \
        -H "Authorization: Bearer priv-key")
    local url
    url=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")

    # URL should contain the proxy prefix
    if ! echo "$url" | grep -q "/storage/"; then
        echo "  FAIL: presigned URL missing /storage/ prefix: $url"
        _proxy_teardown
        return 1
    fi
    echo "  OK: presigned URL includes /storage/ prefix"

    # fetch via presigned URL — should work through proxy
    local body
    body=$(curl -s "$url")
    assert_eq "$body" "presign http" "HTTP presigned URL fetchable through proxy" || { _proxy_teardown; return 1; }

    curl -s -X DELETE "$PROXY_BASE/private-bucket/proxy-httpps.txt" \
        -H "Authorization: Bearer priv-key" >/dev/null

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_http_presign)

test_proxy_master_key() {
    _proxy_setup || return 1

    _run_s3_proxy "test-master-pub" "test-master-key" "
s3.put_object(Bucket='public-bucket', Key='proxy-master.txt', Body=b'master via proxy')
s3.put_object(Bucket='private-bucket', Key='proxy-master.txt', Body=b'master priv via proxy')
resp1 = s3.get_object(Bucket='public-bucket', Key='proxy-master.txt')
resp2 = s3.get_object(Bucket='private-bucket', Key='proxy-master.txt')
assert resp1['Body'].read() == b'master via proxy'
assert resp2['Body'].read() == b'master priv via proxy'
print('ok')
s3.delete_object(Bucket='public-bucket', Key='proxy-master.txt')
s3.delete_object(Bucket='private-bucket', Key='proxy-master.txt')
" || { echo "  FAIL: master key through proxy"; _proxy_teardown; return 1; }
    echo "  OK: master key S3 ops through proxy"

    _proxy_teardown
}
ALL_TESTS+=(test_proxy_master_key)
