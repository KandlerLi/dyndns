"""FRITZ!Box-compatible DynDNS endpoint backed by Amazon Route53."""

from __future__ import annotations

import base64
import binascii
import hmac
import ipaddress
import json
import logging
import os
import time
from typing import Any


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

_route53_client: Any = None
_secrets_client: Any = None
_cached_credentials: tuple[str, str] | None = None
_credentials_cached_at = 0.0
_CREDENTIAL_CACHE_SECONDS = 300


def _client(service_name: str) -> Any:
    global _route53_client, _secrets_client

    if service_name == "route53":
        if _route53_client is None:
            import boto3

            _route53_client = boto3.client("route53")
        return _route53_client

    if service_name == "secretsmanager":
        if _secrets_client is None:
            import boto3

            _secrets_client = boto3.client("secretsmanager")
        return _secrets_client

    raise ValueError(f"Unsupported AWS service: {service_name}")


def _response(status_code: int, body: str, **headers: str) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {
            "content-type": "text/plain; charset=utf-8",
            "cache-control": "no-store",
            **headers,
        },
        "body": body,
    }


def _credentials() -> tuple[str, str]:
    global _cached_credentials, _credentials_cached_at

    now = time.monotonic()
    if (
        _cached_credentials is not None
        and now - _credentials_cached_at < _CREDENTIAL_CACHE_SECONDS
    ):
        return _cached_credentials

    response = _client("secretsmanager").get_secret_value(
        SecretId=os.environ["CREDENTIALS_SECRET_ID"]
    )
    secret = json.loads(response["SecretString"])
    username = secret.get("username")
    password = secret.get("password")

    if not isinstance(username, str) or not isinstance(password, str):
        raise ValueError("Credentials secret must contain string username and password")

    _cached_credentials = (username, password)
    _credentials_cached_at = now
    return _cached_credentials


def _basic_credentials(authorization: str | None) -> tuple[str, str] | None:
    if not authorization or not authorization.lower().startswith("basic "):
        return None

    try:
        encoded = authorization.split(None, 1)[1]
        decoded = base64.b64decode(encoded, validate=True).decode("utf-8")
        username, password = decoded.split(":", 1)
    except (ValueError, UnicodeDecodeError, binascii.Error):
        return None

    return username, password


def _authorized(event: dict[str, Any]) -> bool:
    headers = {key.lower(): value for key, value in (event.get("headers") or {}).items()}
    supplied = _basic_credentials(headers.get("authorization"))
    if supplied is None:
        return False

    expected = _credentials()
    return hmac.compare_digest(supplied[0], expected[0]) and hmac.compare_digest(
        supplied[1], expected[1]
    )


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    try:
        if not _authorized(event):
            return _response(
                401,
                "badauth",
                **{"www-authenticate": 'Basic realm="DynDNS"'},
            )
    except Exception:
        LOGGER.exception("Could not load DynDNS credentials")
        return _response(503, "911")

    parameters = event.get("queryStringParameters") or {}
    hostname = str(parameters.get("hostname", "")).lower().rstrip(".")
    expected_hostname = os.environ["DOMAIN_NAME"].lower().rstrip(".")

    if hostname != expected_hostname:
        return _response(400, "notfqdn")

    try:
        address = ipaddress.ip_address(str(parameters.get("myip", "")))
        if address.version != 4 or not address.is_global:
            raise ValueError("Only public IPv4 addresses are supported")
    except ValueError:
        return _response(400, "dnserr")

    try:
        _client("route53").change_resource_record_sets(
            HostedZoneId=os.environ["HOSTED_ZONE_ID"],
            ChangeBatch={
                "Comment": "Updated by the FRITZ!Box DynDNS endpoint",
                "Changes": [
                    {
                        "Action": "UPSERT",
                        "ResourceRecordSet": {
                            "Name": expected_hostname,
                            "Type": "A",
                            "TTL": int(os.environ["RECORD_TTL"]),
                            "ResourceRecords": [{"Value": str(address)}],
                        },
                    }
                ],
            },
        )
    except Exception:
        LOGGER.exception("Route53 update failed for %s", expected_hostname)
        return _response(503, "911")

    LOGGER.info("Updated %s to %s", expected_hostname, address)
    return _response(200, f"good {address}")
