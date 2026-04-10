from datetime import datetime, timezone
from xml.etree.ElementTree import Element, SubElement, tostring

S3_NS = "http://s3.amazonaws.com/doc/2006-03-01/"
XML_HEADER = '<?xml version="1.0" encoding="UTF-8"?>'


def _to_xml(root: Element) -> str:
    return XML_HEADER + tostring(root, encoding="unicode")


def list_buckets_xml(bucket_names: list[str]) -> str:
    root = Element("ListAllMyBucketsResult", xmlns=S3_NS)
    owner = SubElement(root, "Owner")
    SubElement(owner, "ID").text = "hybrids3"
    SubElement(owner, "DisplayName").text = "hybrids3"
    buckets_el = SubElement(root, "Buckets")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    for name in bucket_names:
        b = SubElement(buckets_el, "Bucket")
        SubElement(b, "Name").text = name
        SubElement(b, "CreationDate").text = now
    return _to_xml(root)


def list_objects_xml(
    bucket: str,
    objects: list[dict],
    prefix: str = "",
    max_keys: int = 1000,
) -> str:
    root = Element("ListBucketResult", xmlns=S3_NS)
    SubElement(root, "Name").text = bucket
    SubElement(root, "Prefix").text = prefix
    SubElement(root, "KeyCount").text = str(len(objects))
    SubElement(root, "MaxKeys").text = str(max_keys)
    SubElement(root, "IsTruncated").text = "false"
    for obj in objects:
        c = SubElement(root, "Contents")
        SubElement(c, "Key").text = obj["key"]
        SubElement(c, "LastModified").text = obj["uploaded_at"]
        SubElement(c, "ETag").text = f"\"{obj['etag']}\""
        SubElement(c, "Size").text = str(obj["size"])
        SubElement(c, "StorageClass").text = "STANDARD"
    return _to_xml(root)


def location_xml() -> str:
    root = Element("LocationConstraint", xmlns=S3_NS)
    return _to_xml(root)


def error_xml(code: str, message: str, request_id: str = "") -> str:
    root = Element("Error")
    SubElement(root, "Code").text = code
    SubElement(root, "Message").text = message
    SubElement(root, "RequestId").text = request_id
    return _to_xml(root)
