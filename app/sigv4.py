"""AWS Signature V4 verification for presigned URLs and header auth.

We verify signatures properly — the public key (aws_access_key_id) alone
grants nothing. The private key (aws_secret_access_key) is needed to sign.
"""

import hashlib
import hmac
import re
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone

from fastapi import Request


@dataclass
class SigV4Credentials:
    access_key: str
    date: str
    region: str
    service: str
    signed_headers: list[str]
    signature: str
    amz_date: str
    expires: int  # 0 for header auth


def _derive_signing_key(secret_key: str, date: str, region: str, service: str) -> bytes:
    k_date = hmac.new(("AWS4" + secret_key).encode(), date.encode(), hashlib.sha256).digest()
    k_region = hmac.new(k_date, region.encode(), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode(), hashlib.sha256).digest()
    return hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()


def _uri_encode(s: str, encode_slash: bool = True) -> str:
    if encode_slash:
        return urllib.parse.quote(s, safe="~")
    return urllib.parse.quote(s, safe="~/")


def _canonical_querystring(params: dict[str, str], exclude: set[str]) -> str:
    pairs = []
    for k in sorted(params):
        if k in exclude:
            continue
        pairs.append(f"{_uri_encode(k)}={_uri_encode(params[k])}")
    return "&".join(pairs)


def parse_presigned(request: Request) -> SigV4Credentials | None:
    """Extract SigV4 credentials from presigned URL query params."""
    algo = request.query_params.get("X-Amz-Algorithm", "")
    if algo != "AWS4-HMAC-SHA256":
        return None
    cred = request.query_params.get("X-Amz-Credential", "")
    amz_date = request.query_params.get("X-Amz-Date", "")
    expires = request.query_params.get("X-Amz-Expires", "0")
    signed_hdrs = request.query_params.get("X-Amz-SignedHeaders", "")
    sig = request.query_params.get("X-Amz-Signature", "")
    if not all([cred, amz_date, sig]):
        return None
    parts = cred.split("/")
    if len(parts) != 5:
        return None
    return SigV4Credentials(
        access_key=parts[0],
        date=parts[1],
        region=parts[2],
        service=parts[3],
        signed_headers=sorted(signed_hdrs.split(";")) if signed_hdrs else [],
        signature=sig,
        amz_date=amz_date,
        expires=int(expires) if expires else 0,
    )


def parse_header(request: Request) -> SigV4Credentials | None:
    """Extract SigV4 credentials from Authorization header."""
    auth = request.headers.get("authorization", "")
    if not auth.startswith("AWS4-HMAC-SHA256"):
        return None
    cred_match = re.search(r"Credential=([^,]+)", auth)
    headers_match = re.search(r"SignedHeaders=([^,]+)", auth)
    sig_match = re.search(r"Signature=([a-f0-9]+)", auth)
    if not all([cred_match, headers_match, sig_match]):
        return None
    cred = cred_match.group(1)  # type: ignore[union-attr]
    parts = cred.split("/")
    if len(parts) != 5:
        return None
    signed_hdrs_str = headers_match.group(1)  # type: ignore[union-attr]
    amz_date = request.headers.get("x-amz-date", "")
    return SigV4Credentials(
        access_key=parts[0],
        date=parts[1],
        region=parts[2],
        service=parts[3],
        signed_headers=sorted(signed_hdrs_str.split(";")),
        signature=sig_match.group(1),  # type: ignore[union-attr]
        amz_date=amz_date,
        expires=0,
    )


def verify_presigned(request: Request, secret_key: str) -> bool:
    """Verify an AWS Sig V4 presigned URL signature."""
    creds = parse_presigned(request)
    if not creds:
        return False

    # build canonical headers from signed headers list
    canonical_headers = ""
    for h in creds.signed_headers:
        val = request.headers.get(h, "")
        canonical_headers += f"{h}:{val.strip()}\n"

    # query params excluding signature
    params = dict(request.query_params)
    canonical_qs = _canonical_querystring(params, {"X-Amz-Signature"})

    # canonical URI — the path
    path = request.url.path or "/"

    canonical_request = (
        f"{request.method}\n"
        f"{path}\n"
        f"{canonical_qs}\n"
        f"{canonical_headers}\n"
        f"{';'.join(creds.signed_headers)}\n"
        "UNSIGNED-PAYLOAD"
    )

    scope = f"{creds.date}/{creds.region}/{creds.service}/aws4_request"
    string_to_sign = (
        f"AWS4-HMAC-SHA256\n"
        f"{creds.amz_date}\n"
        f"{scope}\n"
        f"{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    )

    signing_key = _derive_signing_key(secret_key, creds.date, creds.region, creds.service)
    expected = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

    return hmac.compare_digest(expected, creds.signature)


def generate_presigned_url(
    base_url: str,
    bucket: str,
    key: str,
    public_key: str,
    secret_key: str,
    expires: int = 3600,
    region: str = "us-east-1",
    host: str = "",
) -> str:
    """Generate an AWS Sig V4 presigned GET URL.

    The secret_key signs the URL. Only the public_key appears in the URL.
    """
    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_str = now.strftime("%Y%m%d")

    path = f"/{bucket}/{key}"
    scope = f"{date_str}/{region}/s3/aws4_request"
    credential = f"{public_key}/{scope}"

    params = {
        "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
        "X-Amz-Credential": credential,
        "X-Amz-Date": amz_date,
        "X-Amz-Expires": str(expires),
        "X-Amz-SignedHeaders": "host",
    }
    canonical_qs = _canonical_querystring(params, set())

    if not host:
        parsed = urllib.parse.urlparse(base_url)
        host = parsed.netloc

    canonical_headers = f"host:{host}\n"
    canonical_request = (
        f"GET\n"
        f"{_uri_encode(path, encode_slash=False)}\n"
        f"{canonical_qs}\n"
        f"{canonical_headers}\n"
        f"host\n"
        f"UNSIGNED-PAYLOAD"
    )

    string_to_sign = (
        f"AWS4-HMAC-SHA256\n"
        f"{amz_date}\n"
        f"{scope}\n"
        f"{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    )

    signing_key = _derive_signing_key(secret_key, date_str, region, "s3")
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

    return f"{base_url.rstrip('/')}{path}?{canonical_qs}&X-Amz-Signature={signature}"


def verify_header(request: Request, secret_key: str) -> bool:
    """Verify an AWS Sig V4 Authorization header signature."""
    creds = parse_header(request)
    if not creds:
        return False

    # build canonical headers
    canonical_headers = ""
    for h in creds.signed_headers:
        val = request.headers.get(h, "")
        canonical_headers += f"{h}:{val.strip()}\n"

    # query string from URL
    params = dict(request.query_params)
    canonical_qs = _canonical_querystring(params, set())

    path = request.url.path or "/"

    # payload hash — from x-amz-content-sha256 header or UNSIGNED-PAYLOAD
    payload_hash = request.headers.get("x-amz-content-sha256", "UNSIGNED-PAYLOAD")

    canonical_request = (
        f"{request.method}\n"
        f"{path}\n"
        f"{canonical_qs}\n"
        f"{canonical_headers}\n"
        f"{';'.join(creds.signed_headers)}\n"
        f"{payload_hash}"
    )

    scope = f"{creds.date}/{creds.region}/{creds.service}/aws4_request"
    string_to_sign = (
        f"AWS4-HMAC-SHA256\n"
        f"{creds.amz_date}\n"
        f"{scope}\n"
        f"{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    )

    signing_key = _derive_signing_key(secret_key, creds.date, creds.region, creds.service)
    expected = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

    return hmac.compare_digest(expected, creds.signature)
