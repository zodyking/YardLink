#!/bin/sh
set -eu

echo "=============================================="
echo " Yard Link — starting"
echo "=============================================="

SECRETS_DIR="${YARDLINK_SECRETS_DIR:-/run/yardlink}"

export YARDLINK_DATA_DIR="${YARDLINK_DATA_DIR:-/data}"
mkdir -p "$YARDLINK_DATA_DIR/files"

# Which database to use, in order:
#   1. DATABASE_URL passed in by the host.
#   2. An external database entered in the setup wizard, remembered in the
#      data volume (server/utils/database-config.ts writes this file).
#   3. The built-in database container, with the password the `secrets`
#      service generated on first start.
STORED_DATABASE_URL="$YARDLINK_DATA_DIR/config/database-url"
if [ -n "${DATABASE_URL:-}" ]; then
  export YARDLINK_DATABASE_SOURCE=env
  echo "[entrypoint] Database: external (DATABASE_URL)"
elif [ -s "$STORED_DATABASE_URL" ]; then
  DATABASE_URL="$(tr -d '\r\n' < "$STORED_DATABASE_URL")"
  export DATABASE_URL
  export YARDLINK_DATABASE_SOURCE=wizard
  echo "[entrypoint] Database: external (entered during setup)"
else
  if [ ! -s "$SECRETS_DIR/db-password" ]; then
    echo "[entrypoint] No database password found in $SECRETS_DIR." >&2
    echo "[entrypoint] Start Yard Link with: docker compose up -d" >&2
    exit 1
  fi
  DB_PASSWORD="$(cat "$SECRETS_DIR/db-password")"
  export DATABASE_URL="postgresql://yardlink:${DB_PASSWORD}@${YARDLINK_DB_HOST:-db}:5432/yardlink"
  export YARDLINK_DATABASE_SOURCE=builtin
  echo "[entrypoint] Database: built-in"
fi
export NUXT_DATABASE_URL="$DATABASE_URL"

if [ -z "${NUXT_SESSION_PASSWORD:-}" ]; then
  if [ ! -s "$SECRETS_DIR/session-secret" ]; then
    echo "[entrypoint] No session secret found in $SECRETS_DIR." >&2
    exit 1
  fi
  NUXT_SESSION_PASSWORD="$(cat "$SECRETS_DIR/session-secret")"
  export NUXT_SESSION_PASSWORD
fi

if [ "${SKIP_MIGRATIONS:-false}" = "true" ]; then
  echo "[entrypoint] SKIP_MIGRATIONS=true — skipping database migrations"
else
  echo "[entrypoint] Preparing the database"
  # `set -e` is ignored for every command of an AND-OR list except the last, so
  # the migrator's status has to be tested explicitly. The subshell keeps the
  # migrator's directory change away from the server exec below.
  if ! (cd /app/migrator && node migrate.mjs); then
    echo "[entrypoint] The database could not be prepared — not starting." >&2
    exit 1
  fi
fi

cd /app
echo "[entrypoint] Yard Link is starting on port ${PORT:-3847}"
echo "[entrypoint] Open it in a browser to finish setup or sign in."
exec "$@"
