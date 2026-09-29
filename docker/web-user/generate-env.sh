#!/bin/sh
# Runs automatically on container start (nginx's own /docker-entrypoint.d/
# mechanism) — overwrites the checked-in public/env.js stub with the real
# runtime API URL, since `vite build` already baked import.meta.env.VITE_API_URL
# into the JS bundle and can't be changed after the fact.
set -eu

cat > /usr/share/nginx/html/env.js <<EOF
window.__ENV__ = { VITE_API_URL: "${VITE_API_URL:-}" };
EOF
