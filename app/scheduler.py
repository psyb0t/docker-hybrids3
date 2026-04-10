import asyncio
import sqlite3

from config import DATA_DIR, AppConfig
from db import delete_object_meta, get_all_keys, get_expired_objects
from logger import get_logger
from storage import delete_file, list_bucket_files

log = get_logger(__name__)


async def cleanup_loop(config: AppConfig, conn: sqlite3.Connection) -> None:
    while True:
        await asyncio.sleep(config.cleanup_interval)
        try:
            _run_cleanup(config, conn)
        except Exception:
            log.exception("cleanup error")


def _run_cleanup(config: AppConfig, conn: sqlite3.Connection) -> None:
    # 1. expire objects whose TTL has elapsed
    expired = get_expired_objects(conn)
    for bucket, key in expired:
        delete_object_meta(conn, bucket, key)
        delete_file(DATA_DIR, bucket, key)
        log.info("expired", extra={"bucket": bucket, "key": key})
    if expired:
        log.info("ttl cleanup", extra={"count": len(expired)})

    # 2. delete orphaned files (on disk but not in DB)
    orphans = 0
    for bucket in config.buckets:
        known = get_all_keys(conn, bucket)
        for key in list_bucket_files(DATA_DIR, bucket):
            if key not in known:
                delete_file(DATA_DIR, bucket, key)
                log.info("orphan deleted", extra={"bucket": bucket, "key": key})
                orphans += 1
    if orphans:
        log.info("orphan cleanup", extra={"count": orphans})
