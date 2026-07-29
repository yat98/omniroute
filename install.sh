#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"
NO_START=false
SKIP_PULL=false

usage() {
  cat <<'USAGE'
Pemakaian:
  ./install-omniroute-docker.sh [--dir PATH] [--no-start] [--skip-pull]

Opsi:
  --dir PATH    Folder yang berisi compose.yaml dan .env.
                Default: folder tempat installer berada.
  --no-start    Buat folder data dan validasi konfigurasi saja.
  --skip-pull   Jangan menjalankan docker compose pull.
  -h, --help    Tampilkan bantuan.

Jaminan penyimpanan:
  - Database wajib berada di <folder-proyek>/data/storage.sqlite.
  - Folder /mnt/c, /mnt/d, dan mount Windows lain ditolak.
  - Container dihentikan jika /app/data bukan bind mount yang benar.
  - Database yang sudah ada tidak dihapus atau ditimpa.
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

while (($#)); do
  case "$1" in
    --dir)
      [[ $# -ge 2 ]] || fail "Nilai --dir belum diberikan."
      INSTALL_DIR="$2"
      shift 2
      ;;
    --no-start)
      NO_START=true
      shift
      ;;
    --skip-pull)
      SKIP_PULL=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Opsi tidak dikenal: $1"
      ;;
  esac
done

INSTALL_DIR="$(cd -- "$INSTALL_DIR" 2>/dev/null && pwd)" || \
  fail "Direktori tidak ditemukan: $INSTALL_DIR"

ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
EXPECTED_HOST_DATA_DIR="$INSTALL_DIR/data"

[[ -f "$ENV_FILE" ]] || fail "File wajib tidak ditemukan: $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || fail "File wajib tidak ditemukan: $COMPOSE_FILE"

command -v docker >/dev/null 2>&1 || fail "Docker belum tersedia."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 belum tersedia."
command -v realpath >/dev/null 2>&1 || fail "realpath tidak tersedia (paket coreutils)."
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum tidak tersedia."

read_env_value() {
  local key="$1"
  awk -v wanted="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      pos=index(line, "=")
      if (pos == 0) next
      name=substr(line, 1, pos-1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == wanted) {
        value=substr(line, pos+1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if ((value ~ /^".*"$/) || (value ~ /^'"'"'.*'"'"'$/)) {
          value=substr(value, 2, length(value)-2)
        }
        print value
        exit
      }
    }
  ' "$ENV_FILE"
}

require_value() {
  local key="$1"
  local value
  value="$(read_env_value "$key")"
  [[ -n "$value" ]] || fail "Variabel $key belum diisi di $ENV_FILE"
  printf '%s' "$value"
}

require_boolean() {
  local key="$1"
  local value
  value="$(require_value "$key")"
  case "${value,,}" in
    true|false) printf '%s' "${value,,}" ;;
    *) fail "Nilai $key harus true atau false; saat ini: $value" ;;
  esac
}

reject_placeholder() {
  local key="$1"
  local value
  value="$(require_value "$key")"
  case "$value" in
    CHANGE_ME|changeme|CHANGEME)
      fail "$key masih memakai placeholder CHANGE_ME."
      ;;
  esac
}

HOST_DATA_DIR_RAW="$(require_value HOST_DATA_DIR)"
DATA_DIR_VALUE="$(require_value DATA_DIR)"
CONTAINER_NAME="$(require_value OMNIROUTE_CONTAINER_NAME)"
LIVE_WS_PORT_VALUE="$(require_value LIVE_WS_PORT)"
LIVE_WS_HOST_VALUE="$(require_value LIVE_WS_HOST)"
LIVE_WS_PUBLIC_URL="$(require_value NEXT_PUBLIC_LIVE_WS_PUBLIC_URL)"
LIVE_WS_ENABLED_VALUE="$(require_boolean OMNIROUTE_ENABLE_LIVE_WS)"
QDRANT_ENABLED_VALUE="$(require_boolean QDRANT_ENABLED)"
BIFROST_ENABLED_VALUE="$(require_boolean BIFROST_ENABLED)"
CLIPROXYAPI_ENABLED_VALUE="$(require_boolean CLIPROXYAPI_ENABLED)"

for secret in \
  JWT_SECRET \
  API_KEY_SECRET \
  STORAGE_ENCRYPTION_KEY \
  OMNIROUTE_WS_BRIDGE_SECRET \
  INITIAL_PASSWORD; do
  reject_placeholder "$secret"
done

case "$HOST_DATA_DIR_RAW" in
  /*) ;;
  *) fail "HOST_DATA_DIR harus path absolut; saat ini: $HOST_DATA_DIR_RAW" ;;
esac

case "$HOST_DATA_DIR_RAW" in
  /mnt/*)
    fail "HOST_DATA_DIR berada pada mount Windows: $HOST_DATA_DIR_RAW"
    ;;
esac

[[ "$DATA_DIR_VALUE" == "/app/data" ]] || \
  fail "DATA_DIR wajib /app/data; saat ini: $DATA_DIR_VALUE"

HOST_DATA_DIR="$(realpath -m -- "$HOST_DATA_DIR_RAW")"
EXPECTED_HOST_DATA_DIR="$(realpath -m -- "$EXPECTED_HOST_DATA_DIR")"

[[ "$HOST_DATA_DIR" == "$EXPECTED_HOST_DATA_DIR" ]] || \
  fail "HOST_DATA_DIR harus $EXPECTED_HOST_DATA_DIR; saat ini: $HOST_DATA_DIR"

[[ "$LIVE_WS_ENABLED_VALUE" == "true" ]] || \
  fail "OMNIROUTE_ENABLE_LIVE_WS harus true untuk Live Dashboard."

[[ "$LIVE_WS_HOST_VALUE" == "0.0.0.0" ]] || \
  fail "LIVE_WS_HOST harus 0.0.0.0 di dalam Docker; saat ini: $LIVE_WS_HOST_VALUE"

[[ "$LIVE_WS_PORT_VALUE" =~ ^[0-9]+$ ]] || \
  fail "LIVE_WS_PORT bukan angka: $LIVE_WS_PORT_VALUE"

(( LIVE_WS_PORT_VALUE >= 1 && LIVE_WS_PORT_VALUE <= 65535 )) || \
  fail "LIVE_WS_PORT di luar rentang 1-65535: $LIVE_WS_PORT_VALUE"

case "$LIVE_WS_PUBLIC_URL" in
  ws://localhost:"$LIVE_WS_PORT_VALUE"/live-ws|ws://127.0.0.1:"$LIVE_WS_PORT_VALUE"/live-ws)
    ;;
  *)
    fail "NEXT_PUBLIC_LIVE_WS_PUBLIC_URL harus ws://localhost:${LIVE_WS_PORT_VALUE}/live-ws atau ws://127.0.0.1:${LIVE_WS_PORT_VALUE}/live-ws; saat ini: $LIVE_WS_PUBLIC_URL"
    ;;
esac

DB_PATH="$HOST_DATA_DIR/storage.sqlite"
mkdir -p -- \
  "$HOST_DATA_DIR" \
  "$HOST_DATA_DIR/db_backups" \
  "$HOST_DATA_DIR/logs/application"

WRITE_TEST="$HOST_DATA_DIR/.omniroute-write-test.$$"
: > "$WRITE_TEST" || fail "Folder data tidak dapat ditulis: $HOST_DATA_DIR"
rm -f -- "$WRITE_TEST"

COMPOSE_ARGS=(
  docker compose
  --project-directory "$INSTALL_DIR"
  --env-file "$ENV_FILE"
  -f "$COMPOSE_FILE"
)

[[ "$QDRANT_ENABLED_VALUE" == "true" ]] && COMPOSE_ARGS+=(--profile memory)
[[ "$BIFROST_ENABLED_VALUE" == "true" ]] && COMPOSE_ARGS+=(--profile bifrost)
[[ "$CLIPROXYAPI_ENABLED_VALUE" == "true" ]] && COMPOSE_ARGS+=(--profile cliproxyapi)

ENV_HASH_BEFORE="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
"${COMPOSE_ARGS[@]}" config --quiet
ENV_HASH_AFTER="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
[[ "$ENV_HASH_BEFORE" == "$ENV_HASH_AFTER" ]] || fail ".env berubah selama validasi."

info "Konfigurasi valid"
info "Proyek           : $INSTALL_DIR"
info "Folder data WSL : $HOST_DATA_DIR"
info "Database host   : $DB_PATH"
info "Database Docker : /app/data/storage.sqlite"
info "Live WebSocket  : $LIVE_WS_PUBLIC_URL"
info "Profiles        : memory=$QDRANT_ENABLED_VALUE, bifrost=$BIFROST_ENABLED_VALUE, cliproxyapi=$CLIPROXYAPI_ENABLED_VALUE"

if [[ -e "$DB_PATH" ]]; then
  [[ -f "$DB_PATH" ]] || fail "$DB_PATH ada tetapi bukan file biasa."
  info "Database lama dipertahankan: $(stat -c '%s byte' "$DB_PATH")"
else
  info "storage.sqlite belum ada; OmniRoute akan membuatnya melalui migrasi resmi."
fi

if [[ "$NO_START" == "true" ]]; then
  info "--no-start aktif; container tidak dijalankan."
  exit 0
fi

if [[ "$SKIP_PULL" != "true" ]]; then
  "${COMPOSE_ARGS[@]}" pull
fi

"${COMPOSE_ARGS[@]}" up -d --remove-orphans

stop_for_safety() {
  "${COMPOSE_ARGS[@]}" stop omniroute >/dev/null 2>&1 || true
  fail "$1 Container OmniRoute dihentikan untuk mencegah penulisan data ke lokasi yang salah."
}

# Verifikasi /app/data benar-benar bind mount menuju folder proyek di WSL.
ACTUAL_TYPE="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Type}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
ACTUAL_SOURCE="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"

[[ "$ACTUAL_TYPE" == "bind" && -n "$ACTUAL_SOURCE" ]] || \
  stop_for_safety "Tidak ditemukan bind mount ke /app/data."

ACTUAL_SOURCE="$(realpath -m -- "$ACTUAL_SOURCE")"
[[ "$ACTUAL_SOURCE" == "$HOST_DATA_DIR" ]] || \
  stop_for_safety "Sumber mount $ACTUAL_SOURCE tidak sama dengan $HOST_DATA_DIR."

# Tunggu database terbentuk dan memiliki header SQLite yang valid.
DB_READY=false
for _ in $(seq 1 60); do
  if [[ -f "$DB_PATH" ]] && [[ "$(stat -c '%s' "$DB_PATH" 2>/dev/null || echo 0)" -ge 4096 ]]; then
    DB_READY=true
    break
  fi
  sleep 2
done

[[ "$DB_READY" == "true" ]] || {
  docker logs --tail 120 "$CONTAINER_NAME" >&2 || true
  fail "Database belum terbentuk setelah 120 detik."
}

# Verifikasi integritas SQLite bila Python tersedia.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$DB_PATH" <<'PY'
import sqlite3
import sys

path = sys.argv[1]
conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
tables = conn.execute(
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table'"
).fetchone()[0]
conn.close()

if integrity != "ok":
    raise SystemExit(f"Integrity SQLite gagal: {integrity}")

print(f"Integrity SQLite : {integrity}")
print(f"Jumlah tabel     : {tables}")
PY
else
  info "Python 3 tidak tersedia; PRAGMA integrity_check dilewati."
fi

# Verifikasi proses Live WebSocket mendengarkan di dalam container.
WS_READY=false
for _ in $(seq 1 30); do
  if docker exec \
    -e WS_TEST_PORT="$LIVE_WS_PORT_VALUE" \
    "$CONTAINER_NAME" \
    node -e '
      const net = require("net");
      const socket = net.createConnection({host:"127.0.0.1", port:Number(process.env.WS_TEST_PORT)});
      socket.setTimeout(1500);
      socket.on("connect", () => { socket.destroy(); process.exit(0); });
      socket.on("timeout", () => { socket.destroy(); process.exit(1); });
      socket.on("error", () => process.exit(1));
    ' >/dev/null 2>&1; then
    WS_READY=true
    break
  fi
  sleep 2
done

if [[ "$WS_READY" != "true" ]]; then
  docker logs "$CONTAINER_NAME" 2>&1 | grep -iE 'LiveWS|WebSocket|EADDRINUSE|Failed to start' >&2 || true
  fail "Live WebSocket tidak mendengarkan pada port container $LIVE_WS_PORT_VALUE."
fi

# Verifikasi port yang dipublikasikan Docker tersedia dari WSL host.
if timeout 3 bash -c "</dev/tcp/127.0.0.1/$LIVE_WS_PORT_VALUE" 2>/dev/null; then
  info "Port WebSocket WSL: OPEN (127.0.0.1:$LIVE_WS_PORT_VALUE)"
else
  fail "Port WebSocket WSL tidak dapat dijangkau: 127.0.0.1:$LIVE_WS_PORT_VALUE"
fi

"${COMPOSE_ARGS[@]}" ps

ENV_HASH_AFTER="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
[[ "$ENV_HASH_BEFORE" == "$ENV_HASH_AFTER" ]] || fail ".env berubah selama instalasi."

cat <<EOF

Instalasi tervalidasi.

SQLite persisten:
  $HOST_DATA_DIR -> /app/data
  $DB_PATH

Live WebSocket:
  $LIVE_WS_PUBLIC_URL

Database tetap ada setelah:
  docker compose down
  wsl --shutdown
  restart komputer

Jangan gunakan docker compose down -v ketika Anda tidak ingin menghapus
named volume layanan pendamping seperti Redis/Qdrant.
EOF
