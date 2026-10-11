#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$repo_root" <<'PY'
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
web = root / 'app/build/web'
if not (web / 'index.html').is_file():
    sys.exit('Build the client first: cd app && flutter build web --no-pub')

with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]

with tempfile.TemporaryDirectory(prefix='robot-notes-preview-') as data:
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('ROBOT_NOTES_', 'OTEL_', 'OIDC_'))}
    api_key = secrets.token_urlsafe(24)
    env.update(ROBOT_NOTES_API_KEY=api_key, ROBOT_NOTES_DATA_DIR=data,
               ROBOT_NOTES_PORT=str(port), ROBOT_NOTES_WEB_DIR=str(web))
    print(f'URL: http://127.0.0.1:{port}\nAPI key: {api_key}', flush=True)
    process = subprocess.Popen(
        ['dart_frog', 'dev', '--hostname', '127.0.0.1', '--port', str(port)],
        cwd=root / 'server', env=env,
    )

    def stop(signum, frame):
        process.send_signal(signal.SIGINT)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        sys.exit(process.wait())
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()
PY
