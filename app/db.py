import sqlite3
from datetime import datetime, timedelta, timezone


def init_db(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS objects (
            bucket TEXT NOT NULL,
            key TEXT NOT NULL,
            content_type TEXT DEFAULT 'application/octet-stream',
            size INTEGER NOT NULL,
            etag TEXT NOT NULL,
            uploaded_at TEXT NOT NULL,
            expires_at TEXT,
            PRIMARY KEY (bucket, key)
        )
    """)
    conn.commit()
    return conn


def upsert_object(
    conn: sqlite3.Connection,
    bucket: str,
    key: str,
    content_type: str,
    size: int,
    etag: str,
    ttl_seconds: int,
) -> None:
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat()
    expires_at = None
    if ttl_seconds > 0:
        expires_at = (now + timedelta(seconds=ttl_seconds)).isoformat()
    conn.execute(
        """INSERT OR REPLACE INTO objects
           (bucket, key, content_type, size, etag, uploaded_at, expires_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (bucket, key, content_type, size, etag, now_iso, expires_at),
    )
    conn.commit()


def get_object_meta(conn: sqlite3.Connection, bucket: str, key: str) -> dict | None:
    row = conn.execute("SELECT * FROM objects WHERE bucket=? AND key=?", (bucket, key)).fetchone()
    if not row:
        return None
    return dict(row)


def delete_object_meta(conn: sqlite3.Connection, bucket: str, key: str) -> None:
    conn.execute("DELETE FROM objects WHERE bucket=? AND key=?", (bucket, key))
    conn.commit()


def list_objects_meta(
    conn: sqlite3.Connection,
    bucket: str,
    prefix: str = "",
    max_keys: int = 1000,
) -> list[dict]:
    if prefix:
        # escape LIKE wildcards in user-supplied prefix
        escaped = prefix.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        rows = conn.execute(
            "SELECT * FROM objects WHERE bucket=? AND key LIKE ? ESCAPE '\\'"
            " ORDER BY key LIMIT ?",
            (bucket, escaped + "%", max_keys),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM objects WHERE bucket=? ORDER BY key LIMIT ?",
            (bucket, max_keys),
        ).fetchall()
    return [dict(r) for r in rows]


def get_all_keys(conn: sqlite3.Connection, bucket: str) -> set[str]:
    rows = conn.execute("SELECT key FROM objects WHERE bucket=?", (bucket,)).fetchall()
    return {r["key"] for r in rows}


def get_expired_objects(
    conn: sqlite3.Connection,
) -> list[tuple[str, str]]:
    now = datetime.now(timezone.utc).isoformat()
    rows = conn.execute(
        "SELECT bucket, key FROM objects" " WHERE expires_at IS NOT NULL AND expires_at < ?",
        (now,),
    ).fetchall()
    return [(r["bucket"], r["key"]) for r in rows]
