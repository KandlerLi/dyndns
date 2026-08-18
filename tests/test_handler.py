import base64
import importlib.util
import json
import os
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).parents[1] / "lambda" / "handler.py"
SPEC = importlib.util.spec_from_file_location("dyndns_handler", MODULE_PATH)
handler = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(handler)


class FakeSecretsManager:
    def __init__(self):
        self.calls = 0

    def get_secret_value(self, **_kwargs):
        self.calls += 1
        return {
            "SecretString": json.dumps(
                {"username": "fritzbox", "password": "correct horse battery staple"}
            )
        }


class FakeRoute53:
    def __init__(self):
        self.requests = []

    def change_resource_record_sets(self, **kwargs):
        self.requests.append(kwargs)


class HandlerTest(unittest.TestCase):
    def setUp(self):
        os.environ.update(
            {
                "CREDENTIALS_SECRET_ID": "test-secret",
                "DOMAIN_NAME": "jkandler.de",
                "HOSTED_ZONE_ID": "Z123456789",
                "RECORD_TTL": "60",
            }
        )
        handler._cached_credentials = None
        handler._credentials_cached_at = 0.0
        handler._secrets_client = FakeSecretsManager()
        handler._route53_client = FakeRoute53()

    @staticmethod
    def authorization(username="fritzbox", password="correct horse battery staple"):
        token = base64.b64encode(f"{username}:{password}".encode()).decode()
        return f"Basic {token}"

    def event(self, hostname="jkandler.de", myip="203.0.113.10", authorization=None):
        return {
            "headers": {"authorization": authorization or self.authorization()},
            "queryStringParameters": {"hostname": hostname, "myip": myip},
        }

    def test_updates_the_apex_a_record(self):
        response = handler.lambda_handler(self.event(myip="8.8.8.8"), None)

        self.assertEqual(200, response["statusCode"])
        self.assertEqual("good 8.8.8.8", response["body"])
        request = handler._route53_client.requests[0]
        self.assertEqual("Z123456789", request["HostedZoneId"])
        record = request["ChangeBatch"]["Changes"][0]["ResourceRecordSet"]
        self.assertEqual("jkandler.de", record["Name"])
        self.assertEqual([{"Value": "8.8.8.8"}], record["ResourceRecords"])

    def test_rejects_invalid_credentials(self):
        response = handler.lambda_handler(
            self.event(authorization=self.authorization(password="wrong")), None
        )

        self.assertEqual(401, response["statusCode"])
        self.assertEqual("badauth", response["body"])
        self.assertEqual([], handler._route53_client.requests)

    def test_rejects_an_unexpected_hostname(self):
        response = handler.lambda_handler(self.event(hostname="evil.example"), None)

        self.assertEqual(400, response["statusCode"])
        self.assertEqual("notfqdn", response["body"])
        self.assertEqual([], handler._route53_client.requests)

    def test_rejects_private_or_malformed_addresses(self):
        for address in ("192.168.1.1", "not-an-ip", "2001:db8::1"):
            with self.subTest(address=address):
                response = handler.lambda_handler(self.event(myip=address), None)
                self.assertEqual(400, response["statusCode"])
                self.assertEqual("dnserr", response["body"])

        self.assertEqual([], handler._route53_client.requests)

    def test_caches_credentials_between_invocations(self):
        handler.lambda_handler(self.event(myip="8.8.8.8"), None)
        handler.lambda_handler(self.event(myip="8.8.4.4"), None)

        self.assertEqual(1, handler._secrets_client.calls)


if __name__ == "__main__":
    unittest.main()
