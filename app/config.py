import re
import sys
from dataclasses import dataclass

import pytimeparse2
import yaml

from logger import get_logger

log = get_logger(__name__)

DATA_DIR = "/data"

_SIZE_UNITS = {"b": 1, "kb": 1024, "mb": 1024**2, "gb": 1024**3, "tb": 1024**4}
_SIZE_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*([a-zA-Z]+)\s*$")


@dataclass
class BucketConfig:
    name: str
    public: bool
    key: str  # private key (bearer auth + signing secret)
    public_key: str  # public key (aws_access_key_id, safe to show in URLs)
    ttl_seconds: int  # 0 = never expires
    max_file_size_bytes: int  # 0 = no limit


@dataclass
class AppConfig:
    master_key: str
    master_public_key: str
    cleanup_interval: int
    lock_acquire_timeout: float   # seconds to wait for a lock before 503
    lock_hold_timeout: float      # seconds a lock may be held before 503
    lock_max_waiters: int         # max queued requests per key before 503
    buckets: dict[str, BucketConfig]

    def find_by_public_key(self, public_key: str) -> BucketConfig | None:
        """Look up a bucket by its public key (aws_access_key_id)."""
        if not public_key:
            return None
        for bc in self.buckets.values():
            if bc.public_key == public_key:
                return bc
        return None


def _parse_ttl(raw: str | int | float) -> int:
    """Parse TTL from human-readable string or raw number.

    Accepts: '30s', '5m', '1h', '1h30m12s', '1d', '2d12h', 0, 86400
    Returns seconds as int. 0 means never expires.
    """
    if isinstance(raw, (int, float)):
        return int(raw)
    parsed = pytimeparse2.parse(str(raw))
    if parsed is None:
        log.error("Invalid TTL value: %s", raw)
        sys.exit(1)
    return int(parsed)  # type: ignore[arg-type]


def _parse_size(raw: str | int | float) -> int:
    """Parse file size from human-readable string or raw bytes.

    Accepts: '50MB', '1GB', '500KB', '100mb', 0, 52428800
    Returns bytes as int. 0 means no limit.
    """
    if isinstance(raw, (int, float)):
        return int(raw)
    raw_str = str(raw).strip()
    if raw_str == "0":
        return 0
    m = _SIZE_RE.match(raw_str)
    if not m:
        log.error("Invalid size value: %s", raw)
        sys.exit(1)
    number = float(m.group(1))
    unit = m.group(2).lower()
    if unit not in _SIZE_UNITS:
        log.error("Unknown size unit '%s' in: %s (use B, KB, MB, GB, TB)", unit, raw)
        sys.exit(1)
    return int(number * _SIZE_UNITS[unit])


def load_config(path: str) -> AppConfig:
    try:
        with open(path) as f:
            raw = yaml.safe_load(f)
    except FileNotFoundError:
        log.error("Config file not found: %s", path)
        sys.exit(1)

    if not raw:
        log.error("Config file is empty: %s", path)
        sys.exit(1)

    buckets: dict[str, BucketConfig] = {}
    for name, cfg in raw.get("buckets", {}).items():
        if "/" in name or ".." in name or not name:
            log.error("Invalid bucket name '%s': must not contain '/' or '..'", name)
            sys.exit(1)
        if not cfg.get("key"):
            log.error("Bucket '%s' has no key configured", name)
            sys.exit(1)
        # public_key defaults to bucket name if not set
        public_key = cfg.get("public_key", name)
        buckets[name] = BucketConfig(
            name=name,
            public=cfg.get("public", False),
            key=cfg["key"],
            public_key=public_key,
            ttl_seconds=_parse_ttl(cfg.get("ttl", 0)),
            max_file_size_bytes=_parse_size(cfg.get("max_file_size", 0)),
        )

    if not buckets:
        log.error("No buckets configured")
        sys.exit(1)

    return AppConfig(
        master_key=raw.get("master_key", ""),
        master_public_key=raw.get("master_public_key", "master"),
        cleanup_interval=_parse_ttl(raw.get("cleanup_interval", 60)),
        lock_acquire_timeout=float(raw.get("lock_acquire_timeout", 30)),
        lock_hold_timeout=float(raw.get("lock_hold_timeout", 300)),
        lock_max_waiters=int(raw.get("lock_max_waiters", 100)),
        buckets=buckets,
    )
