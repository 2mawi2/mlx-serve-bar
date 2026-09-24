#!/usr/bin/env python3
"""Mock mlx-serve for lifecycle tests: /health + /metrics.json with synthetic counters."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

START = time.time()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send({"status": "ok"})
        elif self.path == "/metrics.json":
            e = time.time() - START
            gen = int(e * 42.3)
            self._send({
                "counters": {
                    "prompt_tokens_total": 100000 + int(e * 900),
                    "prefill_tokens_total": int(e * 800),
                    "prefix_cache_tokens_total": 50000,
                    "generation_tokens_total": gen,
                    "requests_success_total": int(e * 0.5),
                    "requests_cancelled_total": 0,
                    "prefix_cache_queries_total": 100,
                    "prefix_cache_hits_total": 94,
                },
                "gauges": {
                    "requests_running": 1, "requests_waiting": 0,
                    "gpu_utilization_pct": 42, "memory_mb": 4096,
                    "generation_tokens_live": gen, "prefill_tokens_live": 0,
                    "requests_prefilling": 0,
                },
                "histograms": {
                    "time_to_first_token_seconds": {"count": 50, "sum": 75.0},
                    "e2e_request_latency_seconds": {"count": 50, "sum": 610.0},
                    "prefill_time_seconds": {"count": 50, "sum": 90.0},
                    "decode_time_seconds": {"count": 50, "sum": 300.0},
                    "prompt_tokens": {"count": 50, "sum": 45000},
                },
            })
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 11999
    HTTPServer(("127.0.0.1", port), H).serve_forever()
