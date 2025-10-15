#!/usr/bin/env python3
"""
Simple HTTPS server for serving static files with SSL/TLS support.
Used by riva-http-demo systemd service.
"""
import http.server
import ssl
import sys
import os

def main():
    if len(sys.argv) < 5:
        print("Usage: simple_https_server.py <port> <cert_file> <key_file> <directory>")
        sys.exit(1)

    port = int(sys.argv[1])
    cert_file = sys.argv[2]
    key_file = sys.argv[3]
    directory = sys.argv[4]

    # Verify files exist
    if not os.path.exists(cert_file):
        print(f"Error: Certificate file not found: {cert_file}")
        sys.exit(1)
    if not os.path.exists(key_file):
        print(f"Error: Key file not found: {key_file}")
        sys.exit(1)
    if not os.path.isdir(directory):
        print(f"Error: Directory not found: {directory}")
        sys.exit(1)

    # Change to the directory to serve
    os.chdir(directory)

    # Create HTTP server
    handler = http.server.SimpleHTTPRequestHandler
    httpd = http.server.HTTPServer(('0.0.0.0', port), handler)

    # Wrap with SSL
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_file, key_file)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)

    print(f"Serving HTTPS on 0.0.0.0 port {port} from {directory}...")
    print(f"Using cert: {cert_file}")
    print(f"Using key: {key_file}")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        sys.exit(0)

if __name__ == "__main__":
    main()
