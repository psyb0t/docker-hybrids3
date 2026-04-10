import hashlib
from pathlib import Path


def _safe_path(data_dir: str, bucket: str, key: str) -> Path:
    """Resolve path safely, preventing traversal attacks."""
    base = Path(data_dir).resolve() / bucket
    full = (base / key.lstrip("/")).resolve()
    try:
        full.relative_to(base)
    except ValueError:
        raise ValueError("path traversal detected")
    return full


def ensure_bucket_dir(data_dir: str, bucket: str) -> None:
    (Path(data_dir) / bucket).mkdir(parents=True, exist_ok=True)


def finalize_file(path_obj: Path) -> tuple[int, str]:
    """Hash a file already written to disk. Returns (size, etag)."""
    size = path_obj.stat().st_size
    hasher = hashlib.md5()
    with open(path_obj, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            hasher.update(chunk)
    return size, hasher.hexdigest()


def write_path(data_dir: str, bucket: str, key: str) -> Path:
    """Get the write destination path, creating parent dirs."""
    path = _safe_path(data_dir, bucket, key)
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def read_file(data_dir: str, bucket: str, key: str) -> Path | None:
    path = _safe_path(data_dir, bucket, key)
    if not path.is_file():
        return None
    return path


def list_bucket_files(data_dir: str, bucket: str) -> list[str]:
    """Return all object keys present on disk for a bucket (no tmp files)."""
    bucket_root = Path(data_dir).resolve() / bucket
    if not bucket_root.is_dir():
        return []
    keys = []
    for path in bucket_root.rglob("*"):
        if not path.is_file():
            continue
        if ".tmp." in path.name:
            continue
        keys.append(str(path.relative_to(bucket_root)))
    return keys


def delete_file(data_dir: str, bucket: str, key: str) -> bool:
    path = _safe_path(data_dir, bucket, key)
    if not path.is_file():
        return False
    path.unlink()
    # clean empty parent dirs up to bucket root
    bucket_root = Path(data_dir).resolve() / bucket
    parent = path.parent
    while parent != bucket_root:
        try:
            if not any(parent.iterdir()):
                parent.rmdir()
        except OSError:
            break
        parent = parent.parent
    return True
