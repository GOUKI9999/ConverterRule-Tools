#!/usr/bin/env python3
import json
import os
import sys
import urllib.request
import urllib.error
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "domains.json")
HOP_BY_HOP = {"connection", "transfer-encoding", "content-encoding", "keep-alive", "content-length", "host"}


def load_rules():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def find_rule(path, rules):
    qs = urllib.parse.urlparse(path).query
    params = urllib.parse.parse_qs(qs)
    url_param = params.get("url", [""])[0]
    if not url_param:
        return None
    host = urllib.parse.urlparse(url_param).hostname or ""
    for domain, rule in rules.items():
        if domain in host:
            return rule
    return None


class Handler(BaseHTTPRequestHandler):
    upstream = "http://127.0.0.1:25500"

    def do_GET(self):
        try:
            rules = load_rules()
        except Exception as e:
            rules = {}
            sys.stderr.write(f"failed to load {CONFIG_PATH}: {e}\n")

        rule = find_rule(self.path, rules)
        target = self.upstream.rstrip("/") + self.path

        req = urllib.request.Request(target)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "user-agent", "connection"):
                req.add_header(k, v)

        ua_override = rule.get("user_agent") if rule else None
        if ua_override:
            req.add_header("User-Agent", ua_override)
        elif "User-Agent" in self.headers:
            req.add_header("User-Agent", self.headers["User-Agent"])

        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                body = resp.read()
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() not in HOP_BY_HOP:
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:
            self.send_error(502, f"upstream fetch failed: {e}")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8388
    upstream = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:25500"
    Handler.upstream = upstream
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"listening on :{port} -> {upstream}, rules from {CONFIG_PATH}")
    server.serve_forever()


if __name__ == "__main__":
    main()
