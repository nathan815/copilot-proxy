#!/usr/bin/env python3
"""Ephemeral HTTP server for remote device setup approval.

Flow:
1. Operator runs `setup-claude-remote` (interactive terminal)
2. Remote device curls http://<host>:4141/setup (Caddy proxies non-browser to here)
3. Operator sees request details and approves/denies
4. Approved requests receive the setup script with token embedded
5. Server exits after serving one setup script
"""

import http.server
import os
import socket
import sys
import textwrap
import threading

PORT = int(os.environ.get("SETUP_PORT", "4143"))
PROXY_AUTH_TOKEN = os.environ.get("PROXY_AUTH_TOKEN", "")
PROXY_HOST = os.environ.get("PROXY_HOST", "localhost:4141")
SETUP_SCRIPT_PATH = "/etc/caddy/remote-setup.sh"


class SetupHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self._serve_script()

    def _serve_script(self):
        """Approval flow — serve setup script after operator approval."""
        remote_ip = self.headers.get("X-Forwarded-For", self.client_address[0])
        user_agent = self.headers.get("User-Agent", "unknown")
        try:
            remote_hostname = socket.gethostbyaddr(remote_ip)[0]
        except (socket.herror, socket.gaierror):
            remote_hostname = None

        print(f"\n{'='*50}")
        if remote_hostname:
            print(f"  Setup request from: {remote_hostname} ({remote_ip})")
        else:
            print(f"  Setup request from: {remote_ip}")
        print(f"  User-Agent: {user_agent}")
        print(f"{'='*50}")

        try:
            answer = input("  Approve? [y/N] ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            answer = ""

        if answer == "y":
            print(f"  Approved.")
            try:
                with open(SETUP_SCRIPT_PATH, "r") as f:
                    script = f.read()
                script = script.replace("{{.Req.Host}}", PROXY_HOST)
                script = script.replace(
                    '{{placeholder "http.request.uri.query.token"}}',
                    PROXY_AUTH_TOKEN,
                )
            except FileNotFoundError:
                script = "#!/bin/sh\necho 'Error: setup script not found'\nexit 1\n"

            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(script.encode())
        else:
            print(f"  Denied.")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(textwrap.dedent("""\
                #!/bin/sh
                echo ""
                echo "Setup request was denied."
                echo ""
                exit 1
            """).encode())

        # Exit after one script request
        threading.Thread(target=self.server.shutdown).start()

    def log_message(self, format, *args):
        pass


def main():
    if not PROXY_AUTH_TOKEN:
        print("Error: PROXY_AUTH_TOKEN not set", file=sys.stderr)
        sys.exit(1)

    server = http.server.HTTPServer(("0.0.0.0", PORT), SetupHandler)
    print(f"Remote setup server running on port {PORT}")
    print(f"")
    print(f"On remote device, run:")
    print(f"  curl -s http://{PROXY_HOST}/setup.sh > claude-copilot-proxy.sh && sh claude-copilot-proxy.sh")
    print(f"")
    print(f"Waiting for request... (Ctrl+C to cancel)")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nCancelled.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
