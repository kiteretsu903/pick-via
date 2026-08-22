#!/usr/bin/env python3

import contextlib
import http.client
import io
import json
import pathlib
import re
import selectors
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest import mock


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
SCRIPT_PATH = SCRIPT_DIR / "localhost_probe.py"
sys.path.insert(0, str(SCRIPT_DIR))

try:
    import localhost_probe as probe
except ModuleNotFoundError:
    probe = None


class ReceiverAvailabilityTests(unittest.TestCase):
    def test_receiver_module_exists(self):
        self.assertIsNotNone(probe, "localhost receiver API is not implemented")


@unittest.skipIf(probe is None, "localhost receiver API is not implemented")
class LocalhostProbeTests(unittest.TestCase):
    @contextlib.contextmanager
    def running_server(self, registry):
        server = probe.create_server(registry, port=0)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive(), "receiver thread did not stop")

    def request(self, server, target, headers=None):
        connection = http.client.HTTPConnection(
            probe.LOOPBACK_HOST, server.server_address[1], timeout=5
        )
        try:
            connection.request("GET", target, headers=headers or {})
            response = connection.getresponse()
            return response.status, response.read(), dict(response.getheaders())
        finally:
            connection.close()

    def raw_request(self, server, request_bytes):
        with socket.create_connection(
            (probe.LOOPBACK_HOST, server.server_address[1]), timeout=5
        ) as connection:
            connection.sendall(request_bytes)
            connection.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                chunk = connection.recv(65536)
                if not chunk:
                    return b"".join(chunks)
                chunks.append(chunk)

    def read_json_line(self, process, timeout=5):
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            self.assertTrue(selector.select(timeout), "timed out waiting for receiver output")
            line = process.stdout.readline()
        finally:
            selector.close()
        self.assertTrue(line, "receiver exited before emitting its protocol record")
        return json.loads(line), line

    def test_server_binds_only_ipv4_loopback_with_ephemeral_port(self):
        registry = probe.ProbeRegistry()
        server = probe.create_server(registry, port=0)
        try:
            self.assertEqual(server.server_address[0], "127.0.0.1")
            self.assertGreater(server.server_address[1], 0)
        finally:
            server.server_close()

        with self.assertRaisesRegex(ValueError, "127[.]0[.]0[.]1"):
            probe.create_server(registry, host="0.0.0.0", port=0)

    def test_token_generation_uses_injectable_urlsafe_24_byte_seam(self):
        calls = []
        values = iter(("first_token-A", "second_token-B"))

        def token_factory(byte_count):
            calls.append(byte_count)
            return next(values)

        registry = probe.ProbeRegistry(token_factory=token_factory)
        tokens = [registry.issue_token(), registry.issue_token()]

        self.assertEqual(calls, [24, 24])
        self.assertEqual(tokens, ["first_token-A", "second_token-B"])
        self.assertNotEqual(tokens[0], tokens[1])
        for token in tokens:
            self.assertTrue(token)
            self.assertRegex(token, r"\A[A-Za-z0-9_-]+\Z")

    def test_default_generator_is_secrets_token_urlsafe_24(self):
        with mock.patch.object(
            probe.secrets,
            "token_urlsafe",
            side_effect=("opaque_token-1", "opaque_token-2"),
        ) as token_urlsafe:
            registry = probe.ProbeRegistry()
            first = registry.issue_token()
            second = registry.issue_token()

        self.assertEqual([first, second], ["opaque_token-1", "opaque_token-2"])
        self.assertEqual(token_urlsafe.call_args_list, [mock.call(24), mock.call(24)])

    def test_consumed_token_is_never_reissued(self):
        values = iter(("one-shot-token", "one-shot-token", "fresh-token"))
        registry = probe.ProbeRegistry(token_factory=lambda _: next(values))
        first = registry.issue_token()
        registry.record_request_target("/" + first, "127.0.0.1")

        self.assertEqual(registry.issue_token(), "fresh-token")

    def test_exact_registered_target_returns_204_and_minimal_receipt(self):
        registry = probe.ProbeRegistry(clock=lambda: 1234.5)
        token = registry.issue_token()

        with self.running_server(registry) as server:
            status, body, _ = self.request(
                server,
                "/" + token,
                headers={"X-Probe-Secret": "header-value-must-not-be-recorded"},
            )

        self.assertEqual(status, 204)
        self.assertEqual(body, b"")
        self.assertEqual(
            registry.receipts,
            [
                {
                    "token": token,
                    "receipt_time": 1234.5,
                    "remote_address": "127.0.0.1",
                }
            ],
        )
        self.assertEqual(
            set(registry.receipts[0]), {"token", "receipt_time", "remote_address"}
        )
        self.assertNotIn("header-value-must-not-be-recorded", repr(registry.receipts))

    def test_unknown_target_returns_empty_404_without_receipt(self):
        registry = probe.ProbeRegistry()
        registry.issue_token()

        with self.running_server(registry) as server:
            status, body, _ = self.request(server, "/unregistered-token")

        self.assertEqual((status, body), (404, b""))
        self.assertEqual(registry.receipts, [])

    def test_query_and_path_variants_do_not_match_registered_token(self):
        variants = (
            lambda token: "/" + token + "?extra=1",
            lambda token: "//" + token,
            lambda token: "/prefix/" + token,
            lambda token: "/" + token + "/",
            lambda token: "/" + token + "%2F",
        )

        for variant in variants:
            with self.subTest(variant=variant("TOKEN")):
                registry = probe.ProbeRegistry(token_factory=lambda _: "TOKEN")
                registry.issue_token()
                with self.running_server(registry) as server:
                    status, body, _ = self.request(server, variant("TOKEN"))
                self.assertEqual((status, body), (404, b""))
                self.assertEqual(registry.receipts, [])

    def test_second_token_is_observed_independently(self):
        tokens = iter(("first-token", "second-token"))
        times = iter((10.0, 20.0))
        registry = probe.ProbeRegistry(
            token_factory=lambda _: next(tokens), clock=lambda: next(times)
        )
        first = registry.issue_token()
        second = registry.issue_token()

        with self.running_server(registry) as server:
            self.assertEqual(self.request(server, "/" + second)[:2], (204, b""))
            self.assertEqual(self.request(server, "/" + first)[:2], (204, b""))

        self.assertEqual(
            registry.receipts,
            [
                {
                    "token": second,
                    "receipt_time": 10.0,
                    "remote_address": "127.0.0.1",
                },
                {
                    "token": first,
                    "receipt_time": 20.0,
                    "remote_address": "127.0.0.1",
                },
            ],
        )

    def test_duplicate_and_unregistered_requests_share_empty_404_behavior(self):
        registry = probe.ProbeRegistry(token_factory=lambda _: "one-shot-token")
        token = registry.issue_token()

        with self.running_server(registry) as server:
            accepted = self.request(server, "/" + token)
            duplicate = self.request(server, "/" + token)
            unregistered = self.request(server, "/never-registered")

        self.assertEqual(accepted[:2], (204, b""))
        self.assertEqual(duplicate[:2], (404, b""))
        self.assertEqual(unregistered[:2], (404, b""))
        self.assertEqual(duplicate, unregistered)
        self.assertEqual(len(registry.receipts), 1)

    def test_receipt_limit_atomically_rejects_concurrent_extra_token(self):
        tokens = iter(("first-token", "second-token"))
        registry = probe.ProbeRegistry(
            token_factory=lambda _: next(tokens), receipt_limit=1
        )
        targets = ["/" + registry.issue_token(), "/" + registry.issue_token()]
        barrier = threading.Barrier(3)

        def simultaneous_request(server, target):
            barrier.wait(timeout=5)
            return self.request(server, target)[:2]

        with self.running_server(registry) as server:
            with ThreadPoolExecutor(max_workers=2) as executor:
                futures = [
                    executor.submit(simultaneous_request, server, target)
                    for target in targets
                ]
                barrier.wait(timeout=5)
                results = [future.result(timeout=5) for future in futures]

        self.assertEqual(sorted(results), [(204, b""), (404, b"")])
        self.assertEqual(len(registry.receipts), 1)

    def test_default_request_logging_is_disabled(self):
        registry = probe.ProbeRegistry(token_factory=lambda _: "quiet-token")
        token = registry.issue_token()
        captured_stderr = io.StringIO()

        with contextlib.redirect_stderr(captured_stderr):
            with self.running_server(registry) as server:
                self.request(server, "/" + token)
                self.request(server, "/request-log-secret")

        self.assertEqual(captured_stderr.getvalue(), "")

    def test_http_error_responses_are_empty_and_never_reflect_request_data(self):
        registry = probe.ProbeRegistry()
        malformed_secret = b"/malformed-token?private=query"
        unsupported_secret = b"/unsupported-token?private=query"
        oversized_secret = b"/oversized-token?private=query"
        non_ascii_secret = b"/non-ascii-token-\xff"
        requests = (
            (
                b"GET " + malformed_secret + b" EXTRA HTTP/1.1\r\nHost: loopback\r\n\r\n",
                400,
                malformed_secret,
            ),
            (
                b"POST " + unsupported_secret + b" HTTP/1.1\r\nHost: loopback\r\n\r\n",
                501,
                unsupported_secret,
            ),
            (
                b"GET "
                + oversized_secret
                + (b"x" * 65536)
                + b" HTTP/1.1\r\nHost: loopback\r\n\r\n",
                414,
                oversized_secret,
            ),
            (
                b"GET " + non_ascii_secret + b" HTTP/1.1\r\nHost: loopback\r\n\r\n",
                404,
                non_ascii_secret,
            ),
        )
        captured_stderr = io.StringIO()

        with contextlib.redirect_stderr(captured_stderr):
            with self.running_server(registry) as server:
                for request_bytes, expected_status, secret in requests:
                    with self.subTest(status=expected_status):
                        response = self.raw_request(server, request_bytes)
                        status_line, _, body = response.partition(b"\r\n\r\n")
                        self.assertIn(b" " + str(expected_status).encode() + b" ", status_line)
                        self.assertEqual(body, b"")
                        self.assertNotIn(secret, response)

        self.assertEqual(captured_stderr.getvalue(), "")
        self.assertEqual(registry.receipts, [])

    def test_cli_protocol_is_private_and_exits_after_independent_receipts(self):
        temporary_directory = tempfile.TemporaryDirectory(
            prefix="pickvia-localhost-probe-test-"
        )
        temporary_path = pathlib.Path(temporary_directory.name)
        process = None
        protocol_lines = []
        try:
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--token-count",
                    "2",
                    "--wait-for-receipts",
                    "2",
                ],
                cwd=temporary_directory.name,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            ready, ready_line = self.read_json_line(process)
            protocol_lines.append(ready_line)
            self.assertEqual(set(ready), {"port", "tokens"})
            self.assertEqual(len(ready["tokens"]), 2)
            self.assertEqual(len(set(ready["tokens"])), 2)

            connection = http.client.HTTPConnection(
                "127.0.0.1", ready["port"], timeout=5
            )
            secret_header = "cli-header-value-must-not-appear"
            unexpected_target = "/" + ready["tokens"][0] + "?query-secret=1"
            expected_targets = ["/" + token for token in ready["tokens"]]
            try:
                connection.request(
                    "GET", unexpected_target, headers={"X-Probe-Secret": secret_header}
                )
                response = connection.getresponse()
                self.assertEqual((response.status, response.read()), (404, b""))

                for target in expected_targets:
                    connection.request(
                        "GET", target, headers={"X-Probe-Secret": secret_header}
                    )
                    response = connection.getresponse()
                    self.assertEqual((response.status, response.read()), (204, b""))
            finally:
                connection.close()

            receipts = []
            for _ in range(2):
                receipt, receipt_line = self.read_json_line(process)
                protocol_lines.append(receipt_line)
                receipts.append(receipt)

            self.assertEqual(process.wait(timeout=5), 0)
            remaining_stdout = process.stdout.read()
            stderr = process.stderr.read()
            protocol_lines.append(remaining_stdout)

            self.assertEqual(remaining_stdout, "")
            self.assertEqual(stderr, "")
            self.assertEqual(
                [receipt["token"] for receipt in receipts], ready["tokens"]
            )
            for receipt in receipts:
                self.assertEqual(
                    set(receipt), {"token", "receipt_time", "remote_address"}
                )
                self.assertEqual(receipt["remote_address"], "127.0.0.1")

            combined_output = "".join(protocol_lines) + stderr
            forbidden_values = (
                "http" + "://",
                "https" + "://",
                "?",
                secret_header,
                unexpected_target,
                *expected_targets,
            )
            for forbidden in forbidden_values:
                self.assertNotIn(forbidden, combined_output)
            self.assertEqual(list(temporary_path.iterdir()), [])
        finally:
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()
            temporary_directory.cleanup()
        self.assertFalse(temporary_path.exists())

    def test_cli_rejects_target_arguments_without_echoing_them(self):
        private_target = "http" + "://private.invalid/opaque?secret=1"
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--wait-for-receipts",
                "1",
                private_target,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(private_target, result.stderr)
        self.assertNotIn("http" + "://", result.stderr)
        self.assertNotIn("?", result.stderr)


if __name__ == "__main__":
    unittest.main()
