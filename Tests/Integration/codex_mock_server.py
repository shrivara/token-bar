#!/usr/bin/env python3
"""Minimal local Responses API used by the Codex contract test."""

import http.server
import json
import pathlib
import sys


EVENTS = [
    {
        "type": "response.created",
        "response": {"id": "resp-token-bar"},
    },
    {
        "type": "response.output_item.done",
        "item": {
            "type": "message",
            "role": "assistant",
            "id": "msg-token-bar",
            "content": [{"type": "output_text", "text": "done"}],
        },
    },
    {
        "type": "response.completed",
        "response": {
            "id": "resp-token-bar",
            "usage": {
                "input_tokens": 1234,
                "input_tokens_details": {
                    "cached_tokens": 234,
                    "cache_write_tokens": 111,
                },
                "output_tokens": 345,
                "output_tokens_details": {"reasoning_tokens": 45},
                "total_tokens": 1579,
            },
        },
    },
]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/v1/responses":
            self.send_error(404)
            return

        # The request contents are irrelevant to this test, but consume them so
        # Codex can finish sending before the server writes its response.
        content_length = int(self.headers.get("content-length", "0"))
        self.rfile.read(content_length)

        body = "".join(
            f"event: {event['type']}\ndata: {json.dumps(event)}\n\n"
            for event in EVENTS
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
        raise SystemExit("usage: codex_mock_server.py PORT_FILE")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    pathlib.Path(sys.argv[1]).write_text(str(server.server_port), encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
