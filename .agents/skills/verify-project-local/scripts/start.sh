#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
if [[ ! -f "$repo_dir/app/build/web/index.html" ]]; then
  echo 'Build the current web app first: cd app && flutter build web --no-pub' >&2
  exit 1
fi
verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/robot-notes-verify.XXXXXX")"
verify_port="${VERIFY_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
verify_vm_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
verify_key="$(openssl rand -hex 16)"
trap 'rm -rf -- "$verify_dir"' EXIT
mkdir "$verify_dir/data"
printf 'Disposable local URL: http://127.0.0.1:%s\nDisposable API key: %s\nData directory: %s\nStop with Ctrl-C when verification is complete.\n' "$verify_port" "$verify_key" "$verify_dir/data"
cd "$repo_dir/server"
ROBOT_NOTES_API_KEY="$verify_key" \
ROBOT_NOTES_DATA_DIR="$verify_dir/data" \
ROBOT_NOTES_PORT="$verify_port" \
ROBOT_NOTES_WEB_DIR="$repo_dir/app/build/web" \
  dart_frog dev --hostname 127.0.0.1 --port "$verify_port" --dart-vm-service-port "$verify_vm_port"
