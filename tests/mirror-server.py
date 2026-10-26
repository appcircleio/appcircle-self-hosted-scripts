#!/usr/bin/env python3
"""Local HTTP server that stands in for an artifact proxy in the download-runner tests.

Usage: mirror-server.py <directory> <port-file>

Serves <directory> on 127.0.0.1 and writes the chosen port to <port-file>.
If MIRROR_AUTH is set to "user:password", every request needs those Basic credentials.
"""
import base64
import functools
import http.server
import os
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.authorized():
            super().do_GET()

    def do_HEAD(self):
        if self.authorized():
            super().do_HEAD()

    def authorized(self):
        auth = os.environ.get("MIRROR_AUTH")
        if not auth:
            return True
        expected = "Basic " + base64.b64encode(auth.encode()).decode()
        if self.headers.get("Authorization") == expected:
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="mirror"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False


def main():
    directory, port_file = sys.argv[1], sys.argv[2]
    handler = functools.partial(Handler, directory=directory)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    with open(port_file, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
