#!/usr/bin/env python3
"""Local website preview; --block-storage tests an opaque origin with CSP sandbox.

No settings are changed in the user's browser. Only responses from this local
server receive the test header; the published website does not use this CSP.
"""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=8766)
parser.add_argument('--block-storage', action='store_true')
args = parser.parse_args()


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        path = Path(self.translate_path(self.path))
        if path.is_dir():
            path = path / 'index.html'
        if args.block_storage and path.is_file() and path.suffix == '.html':
            content = path.read_text(encoding='utf-8')
            probe = '''<output id="storage-test-status" hidden></output><script>
try { localStorage.getItem('pickvia-local-test'); document.querySelector('#storage-test-status').value = 'available'; }
catch (error) { document.querySelector('#storage-test-status').value = error.name; }
</script>'''
            body = content.replace('<body>', '<body>' + probe).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        if args.block_storage:
            self.send_header('Content-Security-Policy', 'sandbox allow-scripts allow-top-navigation allow-forms allow-popups')
        super().end_headers()


site = Path(__file__).resolve().parents[1] / 'site'
server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=str(site)))
print(f'Local preview: http://127.0.0.1:{args.port}/; storage blocked: {args.block_storage}', flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    server.server_close()
