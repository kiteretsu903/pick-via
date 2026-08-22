#!/usr/bin/env python3

import argparse
import json
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


LOOPBACK_HOST = "127.0.0.1"
_TOKEN_PATTERN = re.compile(r"\A[A-Za-z0-9_-]+\Z")


class ProbeRegistry:
    def __init__(self, token_factory=None, clock=None, receipt_limit=None):
        if receipt_limit is not None and receipt_limit < 1:
            raise ValueError("receipt limit must be positive")
        self._token_factory = token_factory or secrets.token_urlsafe
        self._clock = clock or time.time
        self._receipt_limit = receipt_limit
        self._issued_tokens = set()
        self._tokens = set()
        self._receipts = []
        self._condition = threading.Condition()

    def issue_token(self):
        while True:
            token = self._token_factory(24)
            if not token or _TOKEN_PATTERN.fullmatch(token) is None:
                raise ValueError("token factory must return a nonempty URL-safe token")
            with self._condition:
                if token not in self._issued_tokens:
                    self._issued_tokens.add(token)
                    self._tokens.add(token)
                    return token

    def record_request_target(self, request_target, remote_address):
        if not request_target.startswith("/"):
            return None
        token = request_target[1:]
        if _TOKEN_PATTERN.fullmatch(token) is None:
            return None
        if remote_address != LOOPBACK_HOST:
            return None

        with self._condition:
            if token not in self._tokens:
                return None
            if (
                self._receipt_limit is not None
                and len(self._receipts) >= self._receipt_limit
            ):
                return None
            self._tokens.remove(token)
            receipt = {
                "token": token,
                "receipt_time": self._clock(),
                "remote_address": remote_address,
            }
            self._receipts.append(receipt)
            self._condition.notify_all()
            return dict(receipt)

    @property
    def receipts(self):
        with self._condition:
            return [dict(receipt) for receipt in self._receipts]

    def wait_for_receipts(self, count):
        with self._condition:
            while len(self._receipts) < count:
                self._condition.wait()
            return [dict(receipt) for receipt in self._receipts[:count]]


def _handler_for(registry):
    class ProbeRequestHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            request_target = self._raw_request_target()
            receipt = registry.record_request_target(
                request_target, self.client_address[0]
            )
            if receipt is None:
                self.send_response_only(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

            self.send_response_only(204)
            self.end_headers()

        def _raw_request_target(self):
            parts = self.raw_requestline.split(b" ", 2)
            if len(parts) < 2:
                return ""
            try:
                return parts[1].decode("ascii")
            except UnicodeDecodeError:
                return ""

        def send_error(self, code, message=None, explain=None):
            self.send_response_only(code)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

        def log_message(self, format_string, *args):
            return

    return ProbeRequestHandler


def create_server(registry, host=LOOPBACK_HOST, port=0):
    if host != LOOPBACK_HOST:
        raise ValueError("receiver must bind exactly 127.0.0.1")
    return ThreadingHTTPServer((host, port), _handler_for(registry))


def _positive_integer(value):
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("value must be positive")
    return parsed


class _PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(2, f"{self.prog}: error: invalid arguments\n")


def main(argv=None):
    parser = _PrivateArgumentParser(
        description="Observe opaque one-shot tokens on an IPv4 loopback socket."
    )
    parser.add_argument("--token-count", type=_positive_integer, default=1)
    parser.add_argument("--wait-for-receipts", type=_positive_integer, required=True)
    arguments = parser.parse_args(argv)
    if arguments.wait_for_receipts > arguments.token_count:
        parser.error("receipt count cannot exceed token count")

    registry = ProbeRegistry(receipt_limit=arguments.wait_for_receipts)
    tokens = [registry.issue_token() for _ in range(arguments.token_count)]
    server = create_server(registry)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        print(
            json.dumps(
                {"port": server.server_address[1], "tokens": tokens},
                separators=(",", ":"),
                sort_keys=True,
            ),
            flush=True,
        )
        receipts = registry.wait_for_receipts(arguments.wait_for_receipts)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

    for receipt in receipts:
        print(json.dumps(receipt, separators=(",", ":"), sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
