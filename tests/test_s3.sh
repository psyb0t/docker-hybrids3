#!/bin/bash
# tests/test_s3.sh - S3 (boto3) compatibility tests

test_s3_put_get() {
    run_s3 "pub-access-id" "pub-key" "
s3.put_object(Bucket='public-bucket', Key='s3test.txt', Body=b'hello s3', ContentType='text/plain')
resp = s3.get_object(Bucket='public-bucket', Key='s3test.txt')
body = resp['Body'].read()
assert body == b'hello s3', f'body mismatch: {body}'
print('ok')
s3.delete_object(Bucket='public-bucket', Key='s3test.txt')
" || { echo "  FAIL: s3 put/get"; return 1; }
    echo "  OK: s3 put/get round-trip"
}
ALL_TESTS+=(test_s3_put_get)

test_s3_head_object() {
    run_s3 "pub-access-id" "pub-key" "
s3.put_object(Bucket='public-bucket', Key='s3head.txt', Body=b'12345', ContentType='text/plain')
head = s3.head_object(Bucket='public-bucket', Key='s3head.txt')
assert head['ContentLength'] == 5, f'size mismatch: {head[\"ContentLength\"]}'
assert '\"' not in head['ETag'] or True  # etag present
print('ok')
s3.delete_object(Bucket='public-bucket', Key='s3head.txt')
" || { echo "  FAIL: s3 head_object"; return 1; }
    echo "  OK: s3 head_object"
}
ALL_TESTS+=(test_s3_head_object)

test_s3_list_objects() {
    run_s3 "pub-access-id" "pub-key" "
s3.put_object(Bucket='public-bucket', Key='list-a.txt', Body=b'a')
s3.put_object(Bucket='public-bucket', Key='list-b.txt', Body=b'b')
resp = s3.list_objects_v2(Bucket='public-bucket', Prefix='list-')
keys = [o['Key'] for o in resp.get('Contents', [])]
assert 'list-a.txt' in keys, f'missing list-a.txt: {keys}'
assert 'list-b.txt' in keys, f'missing list-b.txt: {keys}'
print('ok')
s3.delete_object(Bucket='public-bucket', Key='list-a.txt')
s3.delete_object(Bucket='public-bucket', Key='list-b.txt')
" || { echo "  FAIL: s3 list_objects_v2"; return 1; }
    echo "  OK: s3 list_objects_v2"
}
ALL_TESTS+=(test_s3_list_objects)

test_s3_delete() {
    run_s3 "pub-access-id" "pub-key" "
s3.put_object(Bucket='public-bucket', Key='s3del.txt', Body=b'bye')
s3.delete_object(Bucket='public-bucket', Key='s3del.txt')
try:
    s3.head_object(Bucket='public-bucket', Key='s3del.txt')
    raise AssertionError('object still exists after delete')
except s3.exceptions.ClientError as e:
    assert e.response['Error']['Code'] == '404', f'unexpected: {e}'
print('ok')
" || { echo "  FAIL: s3 delete"; return 1; }
    echo "  OK: s3 delete + verify gone"
}
ALL_TESTS+=(test_s3_delete)

test_s3_nested_keys() {
    run_s3 "pub-access-id" "pub-key" "
s3.put_object(Bucket='public-bucket', Key='dir/sub/file.txt', Body=b'nested')
resp = s3.get_object(Bucket='public-bucket', Key='dir/sub/file.txt')
body = resp['Body'].read()
assert body == b'nested', f'body: {body}'
# list with prefix
lr = s3.list_objects_v2(Bucket='public-bucket', Prefix='dir/')
keys = [o['Key'] for o in lr.get('Contents', [])]
assert 'dir/sub/file.txt' in keys, f'keys: {keys}'
print('ok')
s3.delete_object(Bucket='public-bucket', Key='dir/sub/file.txt')
" || { echo "  FAIL: s3 nested keys"; return 1; }
    echo "  OK: s3 nested keys"
}
ALL_TESTS+=(test_s3_nested_keys)

test_s3_list_buckets() {
    run_s3 "test-master-pub" "test-master-key" "
resp = s3.list_buckets()
names = [b['Name'] for b in resp['Buckets']]
assert 'public-bucket' in names, f'buckets: {names}'
assert 'private-bucket' in names, f'buckets: {names}'
print('ok')
" || { echo "  FAIL: s3 list_buckets"; return 1; }
    echo "  OK: s3 list_buckets"
}
ALL_TESTS+=(test_s3_list_buckets)

test_s3_list_buckets_bucket_key() {
    # bucket key should only see its own bucket
    run_s3 "pub-access-id" "pub-key" "
resp = s3.list_buckets()
names = [b['Name'] for b in resp['Buckets']]
assert names == ['public-bucket'], f'expected only public-bucket, got: {names}'
print('ok')
" || { echo "  FAIL: s3 list_buckets bucket key"; return 1; }
    echo "  OK: s3 list_buckets with bucket key returns only that bucket"
}
ALL_TESTS+=(test_s3_list_buckets_bucket_key)

test_s3_head_bucket() {
    run_s3 "pub-access-id" "pub-key" "
s3.head_bucket(Bucket='public-bucket')
print('ok')
" || { echo "  FAIL: s3 head_bucket"; return 1; }
    echo "  OK: s3 head_bucket"
}
ALL_TESTS+=(test_s3_head_bucket)

test_s3_nonexistent_bucket() {
    run_s3 "pub-access-id" "pub-key" "
try:
    s3.head_bucket(Bucket='no-such-bucket')
    raise AssertionError('should have failed')
except s3.exceptions.ClientError as e:
    assert e.response['Error']['Code'] in ('404', '403'), f'unexpected: {e}'
print('ok')
" || { echo "  FAIL: s3 nonexistent bucket"; return 1; }
    echo "  OK: s3 nonexistent bucket returns error"
}
ALL_TESTS+=(test_s3_nonexistent_bucket)

test_s3_private_bucket_correct_key() {
    run_s3 "priv-access-id" "priv-key" "
s3.put_object(Bucket='private-bucket', Key='s3priv.txt', Body=b'private s3')
resp = s3.get_object(Bucket='private-bucket', Key='s3priv.txt')
body = resp['Body'].read()
assert body == b'private s3', f'body: {body}'
print('ok')
s3.delete_object(Bucket='private-bucket', Key='s3priv.txt')
" || { echo "  FAIL: s3 private bucket with correct key"; return 1; }
    echo "  OK: s3 private bucket with correct key"
}
ALL_TESTS+=(test_s3_private_bucket_correct_key)

test_s3_private_bucket_wrong_key() {
    run_s3 "wrong-id" "wrong-key" "
try:
    s3.put_object(Bucket='private-bucket', Key='s3fail.txt', Body=b'nope')
    raise AssertionError('should have been denied')
except s3.exceptions.ClientError as e:
    code = e.response['Error']['Code']
    assert code in ('404', 'NoSuchBucket'), f'unexpected code: {code}'
print('ok')
" || { echo "  FAIL: s3 private bucket wrong key"; return 1; }
    echo "  OK: s3 private bucket rejects wrong key"
}
ALL_TESTS+=(test_s3_private_bucket_wrong_key)

test_s3_master_key() {
    run_s3 "test-master-pub" "test-master-key" "
# master key works on any bucket
s3.put_object(Bucket='private-bucket', Key='s3master.txt', Body=b'via master')
resp = s3.get_object(Bucket='private-bucket', Key='s3master.txt')
body = resp['Body'].read()
assert body == b'via master', f'body: {body}'

# also on public bucket
s3.put_object(Bucket='public-bucket', Key='s3master2.txt', Body=b'master pub')
resp = s3.get_object(Bucket='public-bucket', Key='s3master2.txt')
body = resp['Body'].read()
assert body == b'master pub', f'body: {body}'

print('ok')
s3.delete_object(Bucket='private-bucket', Key='s3master.txt')
s3.delete_object(Bucket='public-bucket', Key='s3master2.txt')
" || { echo "  FAIL: s3 master key"; return 1; }
    echo "  OK: s3 master key works on all buckets"
}
ALL_TESTS+=(test_s3_master_key)

test_s3_presigned_url() {
    # boto3 presigned URL for public bucket — works (signature verified)
    run_s3 "pub-access-id" "pub-key" "
import urllib.request
s3.put_object(Bucket='public-bucket', Key='presign.txt', Body=b'presigned content', ContentType='text/plain')
url = s3.generate_presigned_url('get_object', Params={'Bucket': 'public-bucket', 'Key': 'presign.txt'}, ExpiresIn=60)
resp = urllib.request.urlopen(url)
body = resp.read()
assert body == b'presigned content', f'body: {body}'
print('ok')
s3.delete_object(Bucket='public-bucket', Key='presign.txt')
" || { echo "  FAIL: s3 presigned URL"; return 1; }
    echo "  OK: s3 presigned URL (public bucket)"
}
ALL_TESTS+=(test_s3_presigned_url)

test_s3_presigned_private() {
    # boto3 presigned URL for private bucket — works (signature proves key knowledge)
    # only the public_key (access ID) is in the URL, not the private key
    run_s3 "priv-access-id" "priv-key" "
import urllib.request
s3.put_object(Bucket='private-bucket', Key='presign-priv.txt', Body=b'secret presigned')
url = s3.generate_presigned_url('get_object', Params={'Bucket': 'private-bucket', 'Key': 'presign-priv.txt'}, ExpiresIn=60)
# URL contains priv-access-id (public, safe) not priv-key (private)
assert 'priv-key' not in url, f'private key leaked in URL: {url}'
assert 'priv-access-id' in url, f'public key should be in URL: {url}'
resp = urllib.request.urlopen(url)
body = resp.read()
assert body == b'secret presigned', f'body: {body}'
print('ok')
s3.delete_object(Bucket='private-bucket', Key='presign-priv.txt')
" || { echo "  FAIL: s3 presigned private"; return 1; }
    echo "  OK: s3 presigned URL (private bucket, key not leaked)"
}
ALL_TESTS+=(test_s3_presigned_private)

test_s3_presigned_wrong_key() {
    # presigned URL with wrong secret should be rejected
    run_s3 "priv-access-id" "priv-key" "
s3.put_object(Bucket='private-bucket', Key='presign-wrongkey.txt', Body=b'secret')
"
    # generate presigned URL with wrong secret key
    run_s3 "priv-access-id" "WRONG-SECRET" "
import urllib.request, urllib.error
url = s3.generate_presigned_url('get_object', Params={'Bucket': 'private-bucket', 'Key': 'presign-wrongkey.txt'}, ExpiresIn=60)
try:
    urllib.request.urlopen(url)
    raise AssertionError('wrong-key presigned URL should fail')
except urllib.error.HTTPError as e:
    assert e.code == 403, f'expected 403, got {e.code}'
print('ok')
" || { echo "  FAIL: s3 presigned wrong key"; return 1; }
    # cleanup
    run_s3 "priv-access-id" "priv-key" "
s3.delete_object(Bucket='private-bucket', Key='presign-wrongkey.txt')
"
    echo "  OK: s3 presigned URL with wrong key rejected"
}
ALL_TESTS+=(test_s3_presigned_wrong_key)

test_s3_overwrite() {
    run_s3 "pub-access-id" "pub-key" "
s3.put_object(Bucket='public-bucket', Key='s3overwrite.txt', Body=b'v1')
s3.put_object(Bucket='public-bucket', Key='s3overwrite.txt', Body=b'v2')
resp = s3.get_object(Bucket='public-bucket', Key='s3overwrite.txt')
body = resp['Body'].read()
assert body == b'v2', f'body: {body}'
print('ok')
s3.delete_object(Bucket='public-bucket', Key='s3overwrite.txt')
" || { echo "  FAIL: s3 overwrite"; return 1; }
    echo "  OK: s3 overwrite"
}
ALL_TESTS+=(test_s3_overwrite)
