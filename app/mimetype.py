import mimetypes
from pathlib import Path

from logger import get_logger

log = get_logger(__name__)

try:
    import magic

    _magic = magic.Magic(mime=True)
except Exception:
    _magic = None
    log.warning("libmagic not available — using extension-only MIME detection")

# types where extension-based detection is more specific than libmagic
_PREFER_EXTENSION = {
    "text/plain",
    "application/octet-stream",
}


def detect(key: str, data: bytes) -> str:
    """Detect MIME type from file content and key extension.

    Uses libmagic for content sniffing, falls back to extension-based
    detection when libmagic returns a generic type or is unavailable.
    """
    sniffed = "application/octet-stream"
    if _magic and data:
        sniffed = _magic.from_buffer(data[:8192])

    # if libmagic gave us something specific, use it
    if sniffed not in _PREFER_EXTENSION:
        return sniffed

    # try extension-based detection
    ext = Path(key).suffix.lower()
    if ext:
        guessed, _ = mimetypes.guess_type(f"file{ext}")
        if guessed:
            return guessed

    return sniffed
