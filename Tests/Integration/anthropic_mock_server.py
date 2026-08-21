#!/usr/bin/env python3
"""Minimal local Anthropic Messages API used by harness contract tests."""

import http.server
import json
import pathlib
import sys
import urllib.parse


EVENTS = [
    (
        "message_start",
        {
            "type": "message_start",
            "message": {
                "id": "msg-token-bar",
                "type": "message",
                "role": "assistant",
                "model": "claude-token-bar-integration",
                "content": [],
                "stop_reason": None,
                "stop_sequence": None,
                "usage": {
                    "input_tokens": 1000,
                    "cache_creation_input_tokens": 111,
                    "cache_read_input_tokens": 234,
                    "output_tokens": 0,
                    "cache_creation": {
                        "ephemeral_5m_input_tokens": 111,
                        "ephemeral_1h_input_tokens": 0,
                    },
                },
            },
        },
    ),
    (
        "content_block_start",
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text", "text": ""},
        },
    ),
    (
        "content_block_delta",
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": "done"},
        },
    ),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    (
        "message_delta",
        {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
            "usage": {
                "input_tokens": 1000,
                "cache_creation_input_tokens": 111,
                "cache_read_input_tokens": 234,
                "output_tokens": 345,
            },
        },
    ),
    ("message_stop", {"type": "message_stop"}),
]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if urllib.parse.urlparse(self.path).path != "/v1/messages":
            self.send_error(404)
            return
        content_length = int(self.headers.get("content-length", "0"))
        self.rfile.read(content_length)

        body = "".join(
            f"event: {event_type}\ndata: {json.dumps(event)}\n\n"
            for event_type, event in EVENTS
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, message, *args):
        print(message % args, file=sys.stderr, flush=True)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: anthropic_mock_server.py PORT_FILE")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    pathlib.Path(sys.argv[1]).write_text(str(server.server_port), encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
