import hmac
import time

from fastapi import Request

from config import AppConfig
from sigv4 import parse_header, parse_presigned, verify_header, verify_presigned


def extract_bearer(request: Request) -> str:
    """Extract bearer token from Authorization header."""
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return ""


def check_bearer(config: AppConfig, bucket_name: str, token: str) -> bool:
    """Check if bearer token matches the bucket's private key or master key."""
    if not token:
        return False
    if config.master_key and hmac.compare_digest(token, config.master_key):
        return True
    bucket = config.buckets.get(bucket_name)
    if not bucket:
        return False
    return hmac.compare_digest(token, bucket.key)


def check_aws_auth(request: Request, config: AppConfig, bucket_name: str) -> bool:
    """Check AWS Sig V4 auth (header or presigned URL).

    Extracts the public key (access_key_id), looks up the bucket,
    then verifies the signature using the bucket's private key.
    The public key alone grants nothing — the signature must be valid.
    """
    # try header auth first
    hdr_creds = parse_header(request)
    if hdr_creds:
        bc = config.find_by_public_key(hdr_creds.access_key)
        if not bc:
            if hdr_creds.access_key == config.master_public_key and config.master_key:
                return verify_header(request, config.master_key)
            return False
        return verify_header(request, bc.key)

    # try presigned URL
    pre_creds = parse_presigned(request)
    if pre_creds:
        # check expiry
        if pre_creds.expires > 0:
            try:
                from datetime import datetime, timezone

                signed_at = datetime.strptime(pre_creds.amz_date, "%Y%m%dT%H%M%SZ").replace(
                    tzinfo=timezone.utc
                )
                if time.time() > signed_at.timestamp() + pre_creds.expires:
                    return False
            except (ValueError, OverflowError):
                return False

        bc = config.find_by_public_key(pre_creds.access_key)
        if not bc:
            if pre_creds.access_key == config.master_public_key and config.master_key:
                return verify_presigned(request, config.master_key)
            return False
        return verify_presigned(request, bc.key)

    return False
