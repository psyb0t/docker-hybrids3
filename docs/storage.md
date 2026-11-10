---
title: "Storage, expiry and locking"
description: "How hybrids3 stores objects: atomic writes, MIME type detection, TTL expiry, the cleanup loop for orphan files, and the per-object read-write locks."
nav_order: 9
---

# Storage, expiry and locking

Each object is a file under `/data/<bucket>/` plus one row in the SQLite database at `/data/hybrids3.db`. This page covers what happens to them on the way in, while they are stored and when they go away. The code is in [`app/storage.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/storage.py), [`app/db.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/db.py), [`app/scheduler.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/scheduler.py) and [`app/lock.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/lock.py).

## Writes

An upload is written to a temporary file next to its destination, named `<name>.tmp.<8 hex digits>`, then renamed over the destination. Readers never see half a file. After the rename hybrids3 computes the MD5 for the ETag, decides the content type and writes the metadata row. If the metadata write fails, the file is deleted again.

HTTP and S3 uploads are streamed to disk in chunks, so a large upload does not sit in memory. The bucket's `max_file_size` is checked while the body arrives, and an upload that crosses it stops with `413`. MCP uploads arrive as one JSON value and are checked after decoding.

Object keys may contain `/`. hybrids3 resolves every key against the bucket directory and rejects one that would land outside it, such as `../../etc/passwd`, with `400 InvalidKey`. Deleting an object removes parent directories that become empty, up to the bucket directory.

## MIME type detection

A client-supplied `Content-Type` is stored as is, unless it is missing, `application/octet-stream` or `application/x-www-form-urlencoded`. For those, hybrids3 detects the type:

1. [libmagic](https://man7.org/linux/man-pages/man3/libmagic.3.html) inspects the first 8 KB of the content.
2. When libmagic answers `text/plain` or `application/octet-stream`, the key's file extension is tried next, so `style.css` becomes `text/css` instead of `text/plain`.
3. If neither gives an answer, the libmagic result stays.

The stored type is returned as `Content-Type` on GET and HEAD and in listings. Detection lives in [`app/mimetype.py`](https://github.com/psyb0t/docker-hybrids3/blob/main/app/mimetype.py).

## TTL expiry

A bucket with `ttl` set gives every object an expiry time of its last write plus the TTL. Writing the same key again starts the clock over. `ttl: 0` means objects never expire, and their `expires_at` is `null`.

```yaml
buckets:
  scratch:
    key: "scratch-secret"
    ttl: 1h
```

Expired objects are not hidden at the moment they expire. They stay readable until the next cleanup run deletes them, so an object can outlive its TTL by up to `cleanup_interval`.

Changing a bucket's `ttl` affects objects written after the restart. Objects already stored keep the expiry time they got when they were written.

## Cleanup loop

A background task wakes up every `cleanup_interval` (60 seconds by default) and does two things:

1. Deletes every object whose `expires_at` has passed, file and metadata row.
2. Walks each configured bucket directory and deletes files that have no metadata row. Those are files left behind by an upload that crashed between the rename and the metadata write, or files put there by hand. Temporary upload files, any name containing `.tmp.`, are skipped, which also means a temporary file left by a container that died mid-upload stays until you delete it.

Each deletion is logged with the bucket and key. An error in one run is logged and the loop carries on. Do not drop files into a bucket directory by hand: the next run deletes them.

## Locking

Every object key has its own read-write lock. Any number of reads can hold it together; a write holds it alone and waits for the reads to finish. Locks are held per key, so traffic on one object never waits for another.

| Operation | Lock |
| --- | --- |
| GET and HEAD, MCP `download_object` | read |
| PUT and DELETE, MCP `upload_object` and `delete_object` | write |
| Listings, MCP `object_info` | none, they only read SQLite |

For a GET, the read lock covers looking up the metadata and the file; the body is streamed after the lock is released. Uploads replace files by rename, so a download that overlaps an upload of the same key can start on the old file after the new one is in place, or fail if the object was deleted in between.

Three limits keep a stuck or overloaded key from piling up requests. Each one ends the request with `503`:

| Limit | Setting | Default | Error code |
| --- | --- | --- | --- |
| Queue full | `lock_max_waiters` | 100 | `ServiceUnavailable` |
| Waited too long for the lock | `lock_acquire_timeout` | 30 seconds | `RequestTimeout` |
| Held the lock too long | `lock_hold_timeout` | 300 seconds | `RequestTimeout` |

The hold timeout exists for slow or stalled uploads, which hold the write lock while the body arrives. When it fires, the upload is abandoned, its temporary file is removed and the lock goes to the next request. Raise it if legitimate uploads take longer than five minutes. For many small objects, lower the acquire timeout and the queue length so overload fails fast.

## Metadata table

```sql
CREATE TABLE objects (
    bucket TEXT NOT NULL,
    key TEXT NOT NULL,
    content_type TEXT DEFAULT 'application/octet-stream',
    size INTEGER NOT NULL,
    etag TEXT NOT NULL,
    uploaded_at TEXT NOT NULL,
    expires_at TEXT,
    PRIMARY KEY (bucket, key)
)
```

Times are UTC ISO 8601 strings. The database runs in WAL mode with a 5 second busy timeout.
