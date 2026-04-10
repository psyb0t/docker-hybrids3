#!/bin/bash
# tests/test_mcp.sh - MCP server tests via fastmcp client

# Helper: run a python MCP client script against $BASE/mcp/
run_mcp() {
    python3 -c "
import asyncio
from fastmcp import Client

async def test():
    client = Client('$BASE/mcp/')
    async with client:
$1

asyncio.run(test())
" 2>&1
}

test_mcp_list_tools() {
    local out
    out=$(run_mcp "
        tools = await client.list_tools()
        names = sorted([t.name for t in tools])
        print(','.join(names))
    ")
    assert_contains "$out" "upload_object" "has upload_object"
    assert_contains "$out" "download_object" "has download_object"
    assert_contains "$out" "delete_object" "has delete_object"
    assert_contains "$out" "list_objects" "has list_objects"
    assert_contains "$out" "list_buckets" "has list_buckets"
    assert_contains "$out" "object_info" "has object_info"
}
ALL_TESTS+=(test_mcp_list_tools)

test_mcp_upload_download() {
    local out
    out=$(run_mcp "
        r = await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-hello.txt',
            'content': 'hello from mcp', 'auth_key': 'pub-key',
            'content_type': 'text/plain',
        })
        data = r.data
        assert data['ok'], f'upload failed: {data}'

        r = await client.call_tool('download_object', {
            'bucket': 'public-bucket', 'key': 'mcp-hello.txt',
        })
        data = r.data
        assert data['ok'], f'download failed: {data}'
        assert data['content'] == 'hello from mcp', f'content: {data[\"content\"]}'
        assert data['encoding'] == 'utf-8'
        print('ok')

        await client.call_tool('delete_object', {
            'bucket': 'public-bucket', 'key': 'mcp-hello.txt', 'auth_key': 'pub-key',
        })
    ") || { echo "  FAIL: mcp upload/download: $out"; return 1; }
    echo "  OK: mcp upload/download round-trip"
}
ALL_TESTS+=(test_mcp_upload_download)

test_mcp_upload_base64() {
    local out
    out=$(run_mcp "
        import base64
        binary = bytes(range(256))
        b64 = base64.b64encode(binary).decode('ascii')

        r = await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-bin.dat',
            'content': b64, 'auth_key': 'pub-key',
            'content_type': 'application/octet-stream', 'encoding': 'base64',
        })
        data = r.data
        assert data['ok'], f'upload failed: {data}'
        assert data['size'] == 256, f'size: {data[\"size\"]}'

        r = await client.call_tool('download_object', {
            'bucket': 'public-bucket', 'key': 'mcp-bin.dat', 'encoding': 'base64',
        })
        data = r.data
        assert data['ok'], f'download failed: {data}'
        got = base64.b64decode(data['content'])
        assert got == binary, 'binary mismatch'
        print('ok')

        await client.call_tool('delete_object', {
            'bucket': 'public-bucket', 'key': 'mcp-bin.dat', 'auth_key': 'pub-key',
        })
    ") || { echo "  FAIL: mcp base64 upload: $out"; return 1; }
    echo "  OK: mcp base64 binary round-trip"
}
ALL_TESTS+=(test_mcp_upload_base64)

test_mcp_delete() {
    local out
    out=$(run_mcp "
        await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-del.txt',
            'content': 'delete me', 'auth_key': 'pub-key',
        })

        r = await client.call_tool('delete_object', {
            'bucket': 'public-bucket', 'key': 'mcp-del.txt', 'auth_key': 'pub-key',
        })
        data = r.data
        assert data['ok'], f'delete failed: {data}'

        r = await client.call_tool('download_object', {
            'bucket': 'public-bucket', 'key': 'mcp-del.txt',
        })
        data = r.data
        assert 'error' in data, 'should be gone after delete'
        print('ok')
    ") || { echo "  FAIL: mcp delete: $out"; return 1; }
    echo "  OK: mcp delete + verify gone"
}
ALL_TESTS+=(test_mcp_delete)

test_mcp_list_objects() {
    local out
    out=$(run_mcp "
        await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-list/a.txt',
            'content': 'a', 'auth_key': 'pub-key',
        })
        await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-list/b.txt',
            'content': 'b', 'auth_key': 'pub-key',
        })
        await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-other.txt',
            'content': 'c', 'auth_key': 'pub-key',
        })

        # list with prefix
        r = await client.call_tool('list_objects', {
            'bucket': 'public-bucket', 'prefix': 'mcp-list/',
        })
        data = r.data
        assert data['ok']
        keys = [o['key'] for o in data['objects']]
        assert 'mcp-list/a.txt' in keys, f'missing a: {keys}'
        assert 'mcp-list/b.txt' in keys, f'missing b: {keys}'
        assert 'mcp-other.txt' not in keys, f'other leaked: {keys}'
        assert data['count'] == 2, f'count: {data[\"count\"]}'
        print('ok')

        for k in ['mcp-list/a.txt', 'mcp-list/b.txt', 'mcp-other.txt']:
            await client.call_tool('delete_object', {
                'bucket': 'public-bucket', 'key': k, 'auth_key': 'pub-key',
            })
    ") || { echo "  FAIL: mcp list_objects: $out"; return 1; }
    echo "  OK: mcp list_objects with prefix"
}
ALL_TESTS+=(test_mcp_list_objects)

test_mcp_list_buckets() {
    local out
    out=$(run_mcp "
        r = await client.call_tool('list_buckets', {'auth_key': 'test-master-key'})
        data = r.data
        assert data['ok'], f'list failed: {data}'
        names = [b['name'] for b in data['buckets']]
        assert 'public-bucket' in names, f'buckets: {names}'
        assert 'private-bucket' in names, f'buckets: {names}'
        print('ok')
    ") || { echo "  FAIL: mcp list_buckets: $out"; return 1; }
    echo "  OK: mcp list_buckets"
}
ALL_TESTS+=(test_mcp_list_buckets)

test_mcp_list_buckets_bucket_key() {
    local out
    out=$(run_mcp "
        r = await client.call_tool('list_buckets', {'auth_key': 'pub-key'})
        data = r.data
        assert data['ok'], f'should work with bucket key: {data}'
        names = [b['name'] for b in data['buckets']]
        assert names == ['public-bucket'], f'should only see own bucket: {names}'
        print('ok')
    ") || { echo "  FAIL: mcp list_buckets bucket key: $out"; return 1; }
    echo "  OK: mcp list_buckets with bucket key returns only that bucket"
}
ALL_TESTS+=(test_mcp_list_buckets_bucket_key)

test_mcp_list_buckets_wrong_key() {
    local out
    out=$(run_mcp "
        r = await client.call_tool('list_buckets', {'auth_key': 'totally-wrong'})
        data = r.data
        assert 'error' in data, f'should be denied: {data}'
        print('ok')
    ") || { echo "  FAIL: mcp list_buckets wrong key: $out"; return 1; }
    echo "  OK: mcp list_buckets denied with invalid key"
}
ALL_TESTS+=(test_mcp_list_buckets_wrong_key)

test_mcp_object_info() {
    local out
    out=$(run_mcp "
        await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-info.txt',
            'content': '12345', 'auth_key': 'pub-key',
            'content_type': 'text/plain',
        })

        r = await client.call_tool('object_info', {
            'bucket': 'public-bucket', 'key': 'mcp-info.txt',
        })
        data = r.data
        assert data['ok'], f'info failed: {data}'
        assert data['size'] == 5, f'size: {data[\"size\"]}'
        assert data['content_type'] == 'text/plain', f'ct: {data[\"content_type\"]}'
        assert data['etag'], 'no etag'
        assert data['uploaded_at'], 'no uploaded_at'
        print('ok')

        await client.call_tool('delete_object', {
            'bucket': 'public-bucket', 'key': 'mcp-info.txt', 'auth_key': 'pub-key',
        })
    ") || { echo "  FAIL: mcp object_info: $out"; return 1; }
    echo "  OK: mcp object_info"
}
ALL_TESTS+=(test_mcp_object_info)

test_mcp_upload_wrong_key() {
    local out
    out=$(run_mcp "
        r = await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'nope.txt',
            'content': 'nope', 'auth_key': 'wrong-key',
        })
        data = r.data
        assert 'error' in data, f'should be denied: {data}'
        assert 'does not exist' in data['error'] or 'denied' in data['error'].lower(), f'error: {data[\"error\"]}'
        print('ok')
    ") || { echo "  FAIL: mcp upload wrong key: $out"; return 1; }
    echo "  OK: mcp upload with wrong key denied"
}
ALL_TESTS+=(test_mcp_upload_wrong_key)

test_mcp_upload_no_key() {
    local out
    out=$(run_mcp "
        r = await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'nope.txt',
            'content': 'nope', 'auth_key': '',
        })
        data = r.data
        assert 'error' in data, f'should be denied: {data}'
        print('ok')
    ") || { echo "  FAIL: mcp upload no key: $out"; return 1; }
    echo "  OK: mcp upload with empty key denied"
}
ALL_TESTS+=(test_mcp_upload_no_key)

test_mcp_private_bucket_read_no_key() {
    local out
    out=$(run_mcp "
        await client.call_tool('upload_object', {
            'bucket': 'private-bucket', 'key': 'mcp-priv.txt',
            'content': 'secret', 'auth_key': 'priv-key',
        })

        # read without key
        r = await client.call_tool('download_object', {
            'bucket': 'private-bucket', 'key': 'mcp-priv.txt',
        })
        data = r.data
        assert 'error' in data, f'should be denied: {data}'

        # read with correct key
        r = await client.call_tool('download_object', {
            'bucket': 'private-bucket', 'key': 'mcp-priv.txt',
            'auth_key': 'priv-key',
        })
        data = r.data
        assert data['ok'], f'should work: {data}'
        assert data['content'] == 'secret'
        print('ok')

        await client.call_tool('delete_object', {
            'bucket': 'private-bucket', 'key': 'mcp-priv.txt', 'auth_key': 'priv-key',
        })
    ") || { echo "  FAIL: mcp private read: $out"; return 1; }
    echo "  OK: mcp private bucket read auth"
}
ALL_TESTS+=(test_mcp_private_bucket_read_no_key)

test_mcp_nonexistent_bucket() {
    local out
    out=$(run_mcp "
        r = await client.call_tool('upload_object', {
            'bucket': 'nope-bucket', 'key': 'x.txt',
            'content': 'x', 'auth_key': 'anything',
        })
        data = r.data
        assert 'error' in data, f'should fail: {data}'
        assert 'does not exist' in data['error'], f'error: {data[\"error\"]}'
        print('ok')
    ") || { echo "  FAIL: mcp nonexistent bucket: $out"; return 1; }
    echo "  OK: mcp nonexistent bucket rejected"
}
ALL_TESTS+=(test_mcp_nonexistent_bucket)

test_mcp_download_nonexistent_object() {
    local out
    out=$(run_mcp "
        r = await client.call_tool('download_object', {
            'bucket': 'public-bucket', 'key': 'does-not-exist.txt',
        })
        data = r.data
        assert 'error' in data, f'should fail: {data}'
        assert 'not found' in data['error'], f'error: {data[\"error\"]}'
        print('ok')
    ") || { echo "  FAIL: mcp download nonexistent: $out"; return 1; }
    echo "  OK: mcp download nonexistent returns error"
}
ALL_TESTS+=(test_mcp_download_nonexistent_object)

test_mcp_size_limit() {
    local out
    out=$(run_mcp "
        big = 'x' * 200  # tiny-bucket max is 100B
        r = await client.call_tool('upload_object', {
            'bucket': 'tiny-bucket', 'key': 'toobig.txt',
            'content': big, 'auth_key': 'tiny-key',
        })
        data = r.data
        assert 'error' in data, f'should fail: {data}'
        assert 'exceeds' in data['error'].lower(), f'error: {data[\"error\"]}'
        print('ok')
    ") || { echo "  FAIL: mcp size limit: $out"; return 1; }
    echo "  OK: mcp size limit enforced"
}
ALL_TESTS+=(test_mcp_size_limit)

test_mcp_master_key_cross_bucket() {
    local out
    out=$(run_mcp "
        # master key uploads to private bucket
        r = await client.call_tool('upload_object', {
            'bucket': 'private-bucket', 'key': 'mcp-master.txt',
            'content': 'via master', 'auth_key': 'test-master-key',
        })
        data = r.data
        assert data['ok'], f'upload failed: {data}'

        # master key reads from private bucket
        r = await client.call_tool('download_object', {
            'bucket': 'private-bucket', 'key': 'mcp-master.txt',
            'auth_key': 'test-master-key',
        })
        data = r.data
        assert data['content'] == 'via master'
        print('ok')

        await client.call_tool('delete_object', {
            'bucket': 'private-bucket', 'key': 'mcp-master.txt',
            'auth_key': 'test-master-key',
        })
    ") || { echo "  FAIL: mcp master key: $out"; return 1; }
    echo "  OK: mcp master key works cross-bucket"
}
ALL_TESTS+=(test_mcp_master_key_cross_bucket)

test_mcp_overwrite() {
    local out
    out=$(run_mcp "
        await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-ow.txt',
            'content': 'v1', 'auth_key': 'pub-key',
        })
        await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-ow.txt',
            'content': 'v2', 'auth_key': 'pub-key',
        })

        r = await client.call_tool('download_object', {
            'bucket': 'public-bucket', 'key': 'mcp-ow.txt',
        })
        data = r.data
        assert data['content'] == 'v2', f'content: {data[\"content\"]}'
        print('ok')

        await client.call_tool('delete_object', {
            'bucket': 'public-bucket', 'key': 'mcp-ow.txt', 'auth_key': 'pub-key',
        })
    ") || { echo "  FAIL: mcp overwrite: $out"; return 1; }
    echo "  OK: mcp overwrite"
}
ALL_TESTS+=(test_mcp_overwrite)

test_mcp_mimetype_auto_detect() {
    local out
    out=$(run_mcp "
        # upload JSON without specifying content_type
        r = await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'auto.json',
            'content': '{\"foo\": \"bar\"}', 'auth_key': 'pub-key',
        })
        data = r.data
        assert data['ok'], f'upload failed: {data}'

        r = await client.call_tool('object_info', {
            'bucket': 'public-bucket', 'key': 'auto.json',
        })
        data = r.data
        assert 'json' in data['content_type'], f'ct: {data[\"content_type\"]}'
        print('ok')

        await client.call_tool('delete_object', {
            'bucket': 'public-bucket', 'key': 'auto.json', 'auth_key': 'pub-key',
        })
    ") || { echo "  FAIL: mcp mimetype auto-detect: $out"; return 1; }
    echo "  OK: mcp mimetype auto-detect"
}
ALL_TESTS+=(test_mcp_mimetype_auto_detect)

test_mcp_presign_url() {
    local out
    out=$(run_mcp "
        import urllib.request

        # upload to private bucket
        await client.call_tool('upload_object', {
            'bucket': 'private-bucket', 'key': 'mcp-presign.txt',
            'content': 'secret presigned', 'auth_key': 'priv-key',
        })

        # generate presigned URL
        r = await client.call_tool('presign_url', {
            'bucket': 'private-bucket', 'key': 'mcp-presign.txt',
            'auth_key': 'priv-key', 'expires': 60,
            'base_url': '$BASE',
        })
        data = r.data
        assert data['ok'], f'presign failed: {data}'
        url = data['url']

        # fetch via presigned URL — no auth header
        body = urllib.request.urlopen(url).read()
        assert body == b'secret presigned', f'body: {body}'
        print('ok')

        await client.call_tool('delete_object', {
            'bucket': 'private-bucket', 'key': 'mcp-presign.txt', 'auth_key': 'priv-key',
        })
    ") || { echo "  FAIL: mcp presign: $out"; return 1; }
    echo "  OK: mcp presign_url works"
}
ALL_TESTS+=(test_mcp_presign_url)

test_mcp_http_interop() {
    # upload via MCP, download via HTTP; upload via HTTP, download via MCP
    local out
    out=$(run_mcp "
        import urllib.request

        # MCP upload
        await client.call_tool('upload_object', {
            'bucket': 'public-bucket', 'key': 'mcp-interop.txt',
            'content': 'from mcp', 'auth_key': 'pub-key',
            'content_type': 'text/plain',
        })

        # HTTP download
        body = urllib.request.urlopen('$BASE/public-bucket/mcp-interop.txt').read()
        assert body == b'from mcp', f'http got: {body}'
        print('http-read ok')
    ") || { echo "  FAIL: mcp→http interop: $out"; return 1; }
    assert_contains "$out" "http-read ok" "MCP upload → HTTP download"

    # HTTP upload
    curl -s -X PUT "$BASE/public-bucket/http-interop.txt" \
        -H "Authorization: Bearer pub-key" -H "Content-Type: text/plain" -d "from http" >/dev/null

    # MCP download
    out=$(run_mcp "
        r = await client.call_tool('download_object', {
            'bucket': 'public-bucket', 'key': 'http-interop.txt',
        })
        data = r.data
        assert data['content'] == 'from http', f'content: {data[\"content\"]}'
        print('ok')
    ") || { echo "  FAIL: http→mcp interop: $out"; return 1; }
    echo "  OK: HTTP upload → MCP download"

    curl -s -X DELETE "$BASE/public-bucket/mcp-interop.txt" -H "Authorization: Bearer pub-key" >/dev/null
    curl -s -X DELETE "$BASE/public-bucket/http-interop.txt" -H "Authorization: Bearer pub-key" >/dev/null
}
ALL_TESTS+=(test_mcp_http_interop)

# ── MCP endpoint-level auth tests ────────────────────────────────────────────

test_mcp_endpoint_bearer_master_key() {
    # valid master key via Bearer header — should pass through to MCP
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BASE/mcp/" \
        -H "Authorization: Bearer test-master-key" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}')
    # MCP server should accept the request (200), not reject with 401
    if [ "$code" = "401" ]; then
        echo "  FAIL: master key Bearer rejected with 401"
        return 1
    fi
    echo "  OK: mcp endpoint accepts master key Bearer"
}
ALL_TESTS+=(test_mcp_endpoint_bearer_master_key)

test_mcp_endpoint_bearer_bucket_key() {
    # valid bucket key via Bearer header — should pass through
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BASE/mcp/" \
        -H "Authorization: Bearer pub-key" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}')
    if [ "$code" = "401" ]; then
        echo "  FAIL: bucket key Bearer rejected with 401"
        return 1
    fi
    echo "  OK: mcp endpoint accepts bucket key Bearer"
}
ALL_TESTS+=(test_mcp_endpoint_bearer_bucket_key)

test_mcp_endpoint_bearer_invalid() {
    # invalid token via Bearer header — should get 401
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BASE/mcp/" \
        -H "Authorization: Bearer totally-wrong-key" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}')
    assert_eq "$code" "401" "invalid Bearer token rejected"
}
ALL_TESTS+=(test_mcp_endpoint_bearer_invalid)

test_mcp_endpoint_query_param_master_key() {
    # valid master key via ?auth= query param
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BASE/mcp/?auth=test-master-key" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}')
    if [ "$code" = "401" ]; then
        echo "  FAIL: master key ?auth= rejected with 401"
        return 1
    fi
    echo "  OK: mcp endpoint accepts master key via ?auth="
}
ALL_TESTS+=(test_mcp_endpoint_query_param_master_key)

test_mcp_endpoint_query_param_bucket_key() {
    # valid bucket key via ?auth= query param
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BASE/mcp/?auth=priv-key" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}')
    if [ "$code" = "401" ]; then
        echo "  FAIL: bucket key ?auth= rejected with 401"
        return 1
    fi
    echo "  OK: mcp endpoint accepts bucket key via ?auth="
}
ALL_TESTS+=(test_mcp_endpoint_query_param_bucket_key)

test_mcp_endpoint_query_param_invalid() {
    # invalid token via ?auth= — should get 401
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BASE/mcp/?auth=wrong-key" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}')
    assert_eq "$code" "401" "invalid ?auth= token rejected"
}
ALL_TESTS+=(test_mcp_endpoint_query_param_invalid)

test_mcp_endpoint_no_token_passes() {
    # no token at all — should pass through (per-tool auth handles access)
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BASE/mcp/" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}')
    if [ "$code" = "401" ]; then
        echo "  FAIL: no-token request rejected with 401"
        return 1
    fi
    echo "  OK: mcp endpoint passes through with no token"
}
ALL_TESTS+=(test_mcp_endpoint_no_token_passes)
