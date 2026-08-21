#!/usr/bin/env python3
"""Minimal local OpenAI Chat Completions API for harness contract tests."""

import http.server
import json
import pathlib
import sys
import time
import urllib.parse


def chunks():
    base = {
        "id": "chatcmpl-token-bar",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": "gpt-token-bar-integration",
    }
    return [
        {
            **base,
            "choices": [
                {
                    "index": 0,
                    "delta": {"role": "assistant", "content": ""},
                    "finish_reason": None,
                }
            ],
        },
        {
            **base,
            "choices": [
                {
                    "index": 0,
                    "delta": {"content": "done"},
                    "finish_reason": None,
                }
            ],
        },
        {
            **base,
            "choices": [
                {"index": 0, "delta": {}, "finish_reason": "stop"}
            ],
        },
        {
            **base,
            "choices": [],
            "usage": {
                "prompt_tokens": 1234,
                "completion_tokens": 345,
                "total_tokens": 1579,
                "prompt_tokens_details": {"cached_tokens": 234},
                "completion_tokens_details": {"reasoning_tokens": 45},
            },
        },
    ]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if urllib.parse.urlparse(self.path).path != "/v1/chat/completions":
            self.send_error(404)
            return
        content_length = int(self.headers.get("content-length", "0"))
        self.rfile.read(content_length)

        body = (
            "".join(f"data: {json.dumps(chunk)}\n\n" for chunk in chunks())
            + "data: [DONE]\n\n"
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
        raise SystemExit("usage: openai_chat_mock_server.py PORT_FILE")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    pathlib.Path(sys.argv[1]).write_text(str(server.server_port), encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
