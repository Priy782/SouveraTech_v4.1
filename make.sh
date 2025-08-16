#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =========================================================
# SouveraTech - make.sh (one-file installer, hardened)
# Cible: Ubuntu/Debian (apt-get) - 100% open-source
# =========================================================

# ---------- Paramètres ----------
PROJECT_NAME="${PROJECT_NAME:-souveratech}"
TARGET_DIR="${HOME}/SouveraTech"
TZ_DEFAULT="${TZ:-Europe/Zurich}"

# Versions images
POSTGRES_VERSION="${POSTGRES_VERSION:-17.5}"
VALKEY_VERSION="${VALKEY_VERSION:-8.1.3}"
QDRANT_VERSION="${QDRANT_VERSION:-1.15.2}"
OPENSEARCH_VERSION="${OPENSEARCH_VERSION:-3.1.0}"
OPENSEARCH_DASH_VERSION="${OPENSEARCH_DASH_VERSION:-3.1.0}"
MINIO_VERSION="${MINIO_VERSION:-RELEASE.2025-07-23T15-54-02Z}"
MC_VERSION="${MC_VERSION:-latest}"
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.3.2}"
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-3.5.0}"
GRAFANA_VERSION="${GRAFANA_VERSION:-12.1.0}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-3.5}"
OLLAMA_VERSION="${OLLAMA_VERSION:-0.11.0}"
OAUTH2_PROXY_VERSION="${OAUTH2_PROXY_VERSION:-v7.6.0}"

# Identifiants/dev
PG_DB="${PG_DB:-souveratech}"
PG_USER="${PG_USER:-st_user}"
PG_PASS="${PG_PASS:-st_pass}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minio}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minio123}"
KC_BOOTSTRAP_ADMIN_USERNAME="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"
KC_BOOTSTRAP_ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-admin}"
# Mot de passe admin OpenSearch (doit respecter la complexité)
OPENSEARCH_ADMIN_PASSWORD="${OPENSEARCH_ADMIN_PASSWORD:-StrongP@ssw0rd!}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-api}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-REPLACE_WITH_SECRET}"   # sera remplacé automatiquement après création du client

# i18n embeddings
QDRANT_COLLECTION="${QDRANT_COLLECTION:-i18n_embeddings}"
EMBED_MODEL="${EMBED_MODEL:-sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2}"

# ------- Helpers -------
log() { printf '%s %s\n' "[$(date +%H:%M:%S)]" "$*"; }
die() { echo "ERREUR: $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

ensure_pkg() {
  if ! has apt-get; then die "Ce script cible Ubuntu/Debian (apt-get)."; fi
  sudo apt-get update -y
  sudo apt-get install -y "$@"
}

# Docker wrapper (bascule sudo auto si nécessaire)
DOCKER="docker"
docker_try() {
  if $DOCKER "$@" >/dev/null 2>&1; then return 0; fi
  if has sudo; then DOCKER="sudo docker"; $DOCKER "$@" >/dev/null; else return 1; fi
}

compose_file="infra/compose/docker-compose.yml"

compose_network() {
  local n="${PROJECT_NAME}_default"
  if $DOCKER network inspect "$n" >/dev/null 2>&1; then echo "$n"; return; fi
  local any="$($DOCKER compose -f "$compose_file" ps -q | head -n1 || true)"
  if [ -n "${any:-}" ]; then
    $DOCKER inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$any" | head -n1
    return
  fi
  echo "bridge"
}

# Attente HTTP depuis l’hôte
wait_http() {
  local url="$1" timeout="${2:-180}" t=0
  until curl -fsS --max-time 2 "$url" >/dev/null 2>&1; do
    sleep 2; t=$((t+2)); [ "$t" -ge "$timeout" ] && return 1
  done
}

# Attente conteneur healthy (ou running si pas de healthcheck)
wait_container() {
  local svc="$1" timeout="${2:-180}" t=0 cid status state
  cid="$($DOCKER compose -f "$compose_file" ps -q "$svc")"
  [ -n "$cid" ] || die "Conteneur $svc introuvable"
  while true; do
    status="$($DOCKER inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
    if [ "$status" = "healthy" ]; then return 0; fi
    if [ "$status" = "unknown" ]; then
      state="$($DOCKER inspect -f '{{.State.Status}}' "$cid")"
      [ "$state" = "running" ] && return 0
    fi
    sleep 2; t=$((t+2)); [ "$t" -ge "$timeout" ] && die "$svc pas healthy après ${timeout}s"
  done
}

# ---------- Étapes ----------
step_setup_host() {
  log "Préparation machine (packages, Docker, sysctl, swap, timezone)"
  ensure_pkg git make jq yq curl openssl ca-certificates gnupg lsb-release uidmap net-tools unzip wget

  if ! has docker; then curl -fsSL https://get.docker.com | sh; fi
  if ! id -nG "$USER" | grep -qw docker; then sudo usermod -aG docker "$USER" || true; fi

  echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/90-souveratech.conf >/dev/null
  sudo sysctl --system >/dev/null

  if ! sudo swapon --show | grep -q '^'; then
    sudo fallocate -l 8G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    sudo swapon /swapfile
  fi

  sudo timedatectl set-timezone "$TZ_DEFAULT" || true

  docker_try version || die "Docker indisponible"
  $DOCKER --version >/dev/null
}

step_scaffold() {
  log "Création arborescence et fichiers"
  mkdir -p "${TARGET_DIR}"/{infra/compose,ops/{sql,minio,i18n},apps/_template,apps/ui}
  cd "${TARGET_DIR}"

  # .env pour compose (même dossier que docker-compose.yml)
  cat > infra/compose/.env <<EOF
PROJECT_NAME=${PROJECT_NAME}
POSTGRES_VERSION=${POSTGRES_VERSION}
VALKEY_VERSION=${VALKEY_VERSION}
QDRANT_VERSION=${QDRANT_VERSION}
OPENSEARCH_VERSION=${OPENSEARCH_VERSION}
OPENSEARCH_DASH_VERSION=${OPENSEARCH_DASH_VERSION}
MINIO_VERSION=${MINIO_VERSION}
MC_VERSION=${MC_VERSION}
KEYCLOAK_VERSION=${KEYCLOAK_VERSION}
PROMETHEUS_VERSION=${PROMETHEUS_VERSION}
GRAFANA_VERSION=${GRAFANA_VERSION}
TRAEFIK_VERSION=${TRAEFIK_VERSION}
OLLAMA_VERSION=${OLLAMA_VERSION}
OAUTH2_PROXY_VERSION=${OAUTH2_PROXY_VERSION}
PG_DB=${PG_DB}
PG_USER=${PG_USER}
PG_PASS=${PG_PASS}
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
KC_BOOTSTRAP_ADMIN_USERNAME=${KC_BOOTSTRAP_ADMIN_USERNAME}
KC_BOOTSTRAP_ADMIN_PASSWORD=${KC_BOOTSTRAP_ADMIN_PASSWORD}
TZ=${TZ_DEFAULT}
OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_ADMIN_PASSWORD}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
EOF

  # secret cookie oauth2-proxy
  if [ ! -f infra/compose/.env.proxy ]; then
    echo "OAUTH2_PROXY_COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '\n')" > infra/compose/.env.proxy
  fi

  # .env.app pour microservices
  cat > .env.app <<EOF
DATABASE_URL=postgresql://${PG_USER}:${PG_PASS}@postgres:5432/${PG_DB}
OIDC_ISSUER=http://keycloak:8080/realms/${PROJECT_NAME}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
API_HOST=0.0.0.0
API_PORT=8080
TZ=${TZ_DEFAULT}
EOF

  # Prometheus (ajout des cibles apps)
  cat > infra/compose/prometheus.yml <<'EOF'
global: { scrape_interval: 15s }
scrape_configs:
- job_name: self
  static_configs: [{ targets: ['prometheus:9090'] }]
- job_name: souveratech-apps
  static_configs:
    - targets:
      - core-meta:8080
      - scheduler:8080
      - core-security:8080
      - core-i18n:8080
      - core-versioning:8080
      - core-graph:8080
      - notifications:8080
      - etl:8080
      - discovery:8080
EOF

  # docker-compose minimal d’infra + apps
  cat > "$compose_file" <<'YAML'
name: ${PROJECT_NAME}
services:
  postgres:
    image: postgres:${POSTGRES_VERSION}
    environment:
      POSTGRES_DB: ${PG_DB}
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASS}
      TZ: ${TZ}
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 5s
      timeout: 3s
      retries: 60
    ports: ["5432:5432"]
    volumes: [ "pgdata:/var/lib/postgresql/data" ]

  valkey:
    image: valkey/valkey:${VALKEY_VERSION}
    command: ["valkey-server","--save","60","1000","--appendonly","yes"]
    ports: ["6379:6379"]

  qdrant:
    image: qdrant/qdrant:v${QDRANT_VERSION}
    ports: ["6333:6333","6334:6334"]
    volumes: [ "qdrant:/qdrant/storage" ]

  opensearch:
    image: opensearchproject/opensearch:${OPENSEARCH_VERSION}
    environment:
      - discovery.type=single-node
      - OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_INITIAL_ADMIN_PASSWORD}
      - OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g
      - plugins.security.ssl.http.enabled=false   # <— hinzufügen

    ulimits:
      memlock: {soft: -1, hard: -1}
      nofile: {soft: 65536, hard: 65536}
    ports: ["9200:9200","9600:9600"]
    volumes: [ "opensearch:/usr/share/opensearch/data" ]

  opensearch-dashboards:
    image: opensearchproject/opensearch-dashboards:${OPENSEARCH_DASH_VERSION}
    environment:
      - OPENSEARCH_HOSTS=["http://opensearch:9200"]
    ports: ["5601:5601"]
    depends_on: [ opensearch ]
    labels:
      traefik.enable: "true"
      traefik.http.routers.osd.rule: Host(`osd.localhost`)
      traefik.http.routers.osd.entrypoints: web
      traefik.http.services.osd.loadbalancer.server.port: "5601"

  minio:
    image: minio/minio:${MINIO_VERSION}
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    ports: ["9000:9000","9001:9001"]
    volumes: [ "minio:/data" ]

  keycloak:
    image: quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}
    command: start-dev
    environment:
      KC_HOSTNAME: localhost
      KC_BOOTSTRAP_ADMIN_USERNAME: ${KC_BOOTSTRAP_ADMIN_USERNAME}
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KC_BOOTSTRAP_ADMIN_PASSWORD}
      TZ: ${TZ}
    ports: ["8088:8080"]

  prometheus:
    image: prom/prometheus:v${PROMETHEUS_VERSION}
    ports: ["9090:9090"]
    volumes: [ "./prometheus.yml:/etc/prometheus/prometheus.yml:ro" ]

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    ports: ["3000:3000"]

  traefik:
    image: traefik:v${TRAEFIK_VERSION}
    command: [ "--api.insecure=true","--providers.docker=true","--entryPoints.web.address=:80","--entryPoints.websecure.address=:443" ]
    ports: ["80:80","443:443"]
    volumes: [ "/var/run/docker.sock:/var/run/docker.sock:ro" ]

  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:${OAUTH2_PROXY_VERSION}
    env_file:
      - ./.env.proxy
      - ./.env
    environment:
      OAUTH2_PROXY_PROVIDER: oidc
      OAUTH2_PROXY_OIDC_ISSUER_URL: http://keycloak:8080/realms/${PROJECT_NAME}
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      OAUTH2_PROXY_UPSTREAMS: "file:///dev/null"
      OAUTH2_PROXY_REVERSE_PROXY: "true"
    ports: ["4180:4180"]
    depends_on: [ keycloak ]
    labels:
      traefik.enable: "true"
      traefik.http.middlewares.auth.forwardauth.address: "http://oauth2-proxy:4180/oauth2/auth"
      traefik.http.middlewares.auth.forwardauth.authResponseHeaders: "X-Auth-Request-Email,Authorization"

  ollama:
    image: ollama/ollama:${OLLAMA_VERSION}
    ports: ["11434:11434"]
    volumes: [ "ollama:/root/.ollama" ]

  # Services applicatifs (buildés plus tard)
  core-meta:
    build: { context: ../../apps/core-meta }
    env_file: [ ../../.env.app, ../../apps/core-meta/.env ]
    depends_on: [ postgres ]
    ports: ["18081:8080"]
    labels:
      traefik.enable: "true"
      traefik.http.routers.coremeta.rule: PathPrefix(`/api/meta`)
      traefik.http.routers.coremeta.entrypoints: web
      traefik.http.routers.coremeta.middlewares: auth@docker
      traefik.http.services.coremeta.loadbalancer.server.port: "8080"

  scheduler:
    build: { context: ../../apps/scheduler }
    env_file: [ ../../.env.app, ../../apps/scheduler/.env ]
    depends_on: [ postgres ]
    ports: ["18082:8080"]
    labels:
      traefik.enable: "true"
      traefik.http.routers.scheduler.rule: PathPrefix(`/api/scheduled_jobs`)
      traefik.http.routers.scheduler.entrypoints: web
      traefik.http.routers.scheduler.middlewares: auth@docker
      traefik.http.services.scheduler.loadbalancer.server.port: "8080"

  core-security:
    build: { context: ../../apps/core-security }
    env_file: [ ../../.env.app, ../../apps/core-security/.env ]
    depends_on: [ postgres ]
    ports: ["18083:8080"]

  core-i18n:
    build: { context: ../../apps/core-i18n }
    env_file: [ ../../.env.app, ../../apps/core-i18n/.env ]
    depends_on: [ postgres, qdrant ]
    ports: ["18084:8080"]

  core-versioning:
    build: { context: ../../apps/core-versioning }
    env_file: [ ../../.env.app, ../../apps/core-versioning/.env ]
    depends_on: [ postgres ]
    ports: ["18085:8080"]

  core-graph:
    build: { context: ../../apps/core-graph }
    env_file: [ ../../.env.app, ../../apps/core-graph/.env ]
    depends_on: [ postgres ]
    ports: ["18086:8080"]

  notifications:
    build: { context: ../../apps/notifications }
    env_file: [ ../../.env.app, ../../apps/notifications/.env ]
    depends_on: [ postgres ]
    ports: ["18087:8080"]

  etl:
    build: { context: ../../apps/etl }
    env_file: [ ../../.env.app, ../../apps/etl/.env ]
    depends_on: [ postgres ]
    ports: ["18088:8080"]

  discovery:
    build: { context: ../../apps/discovery }
    env_file: [ ../../.env.app, ../../apps/discovery/.env ]
    depends_on: [ postgres ]
    ports: ["18089:8080"]

  ui:
    build: { context: ../../apps/ui }
    ports: ["8085:80"]
    labels:
      traefik.enable: "true"
      traefik.http.routers.ui.rule: PathPrefix(`/`)
      traefik.http.routers.ui.entrypoints: web
      traefik.http.services.ui.loadbalancer.server.port: "80"

volumes:
  pgdata: {}
  qdrant: {}
  minio: {}
  opensearch: {}
  ollama: {}
YAML

  # UI minimale
  cat > apps/ui/Dockerfile <<'EOF'
FROM nginx:1.27-alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
EOF

  cat > apps/ui/index.html <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>SouveraTech UI</title></head>
<body>
<h1>SouveraTech — UI minimale</h1>
<button id="load">Charger objets</button>
<pre id="out"></pre>
<script>
document.getElementById('load').onclick = async () => {
  const r = await fetch('/api/meta/objects', {credentials:'include'});
  const j = await r.json();
  document.getElementById('out').textContent = JSON.stringify(j, null, 2);
};
</script>
</body></html>
HTML

  # Template microservice
  cat > apps/_template/requirements.txt <<'EOF'
fastapi==0.115.4
uvicorn==0.30.6
psycopg[binary]==3.2.1
python-dotenv==1.0.1
prometheus-client==0.20.0
EOF

  cat > apps/_template/app.py <<'PY'
import os, json
from fastapi import FastAPI, Request, HTTPException, Body
from fastapi.responses import PlainTextResponse
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import psycopg
from psycopg.rows import dict_row

S = os.getenv("SERVICE_NAME","service")
DB = os.getenv("DATABASE_URL")
app = FastAPI(title=f"SouveraTech {S}")

REQ = Counter("souveratech_requests_total","Requests",["service","route","method","code"])
LAT = Histogram("souveratech_request_duration_seconds","Latency",["service","route","method"])

@app.middleware("http")
async def mw(request: Request, call_next):
  route, method = request.url.path, request.method
  with LAT.labels(S,route,method).time():
    try:
      resp = await call_next(request)
      REQ.labels(S,route,method,resp.status_code).inc()
      return resp
    except Exception:
      REQ.labels(S,route,method,500).inc()
      raise

@app.get("/healthz")
def healthz():
  return {"ok": True, "service": S}

@app.get("/metrics")
def metrics():
  return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)

def conn():
  if not DB: raise RuntimeError("DATABASE_URL missing")
  return psycopg.connect(DB, row_factory=dict_row)

# core-meta
@app.get("/api/meta/objects")
def list_objects():
  if S!="core-meta": return []
  with conn() as c, c.cursor() as cur:
    cur.execute("SELECT name,label,parent_name,version FROM sys_db_object ORDER BY name")
    return cur.fetchall()

@app.post("/api/meta/objects")
def create_object(payload: dict = Body(...)):
  if S!="core-meta": raise HTTPException(404)
  with conn() as c, c.cursor() as cur:
    cur.execute("INSERT INTO sys_db_object(name,label,parent_name) VALUES(%s,%s,%s) ON CONFLICT DO NOTHING",
                (payload["name"], json.dumps(payload.get("label",{})), payload.get("parent","core.work")))
    c.commit(); return {"ok": True}

@app.get("/api/meta/fields")
def list_fields(object: str):
  if S!="core-meta": return []
  with conn() as c, c.cursor() as cur:
    cur.execute("SELECT object_name,name,type,label,required FROM sys_dictionary WHERE object_name=%s ORDER BY name",(object,))
    return cur.fetchall()

@app.post("/api/meta/fields")
def create_field(payload: dict = Body(...)):
  if S!="core-meta": raise HTTPException(404)
  with conn() as c, c.cursor() as cur:
    cur.execute("INSERT INTO sys_dictionary(object_name,name,type,label,required,settings) VALUES(%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                (payload["object"], payload["name"], payload["type"], json.dumps(payload.get("label",{})), bool(payload.get("required",False)), json.dumps(payload.get("settings",{}))))
    c.commit(); return {"ok": True}

# scheduler minimal
@app.get("/api/scheduled_jobs")
def list_jobs():
  if S!="scheduler": return []
  with conn() as c, c.cursor() as cur:
    cur.execute("SELECT job_key,enabled,schedule,action FROM scheduled_jobs ORDER BY job_key")
    return cur.fetchall()
PY

  cat > apps/_template/Dockerfile <<'EOF'
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 8080
CMD ["sh","-lc","uvicorn app:app --host ${API_HOST:-0.0.0.0} --port ${API_PORT:-8080}"]
EOF

  # Instanciation des services
  (
    cd apps
    for S in core-meta scheduler core-security core-i18n core-versioning core-graph notifications etl discovery; do
      mkdir -p "$S"
      cp -a _template/* "$S/"
      echo "SERVICE_NAME=$S" > "$S/.env"
    done
  )

  # SQL noyau + seeds (Partie 2 complète)
  cat > ops/sql/000_init.sql <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1) META
CREATE TABLE IF NOT EXISTS sys_db_object (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL UNIQUE,
  label JSONB NOT NULL DEFAULT '{}'::jsonb,
  description TEXT DEFAULT NULL,
  version INT NOT NULL DEFAULT 1,
  parent_name TEXT DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS sys_dictionary (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  object_name TEXT NOT NULL REFERENCES sys_db_object(name) ON DELETE CASCADE,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  label JSONB NOT NULL DEFAULT '{}'::jsonb,
  required BOOLEAN NOT NULL DEFAULT false,
  default_value JSONB DEFAULT NULL,
  settings JSONB NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE(object_name, name)
);
CREATE TABLE IF NOT EXISTS records (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  object_name TEXT NOT NULL REFERENCES sys_db_object(name) ON DELETE CASCADE,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  number TEXT DEFAULT NULL,
  created_by UUID DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);

-- 2) VERSIONING
CREATE TABLE IF NOT EXISTS object_versions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  object_name TEXT NOT NULL,
  record_id UUID NOT NULL,
  parent_version_id UUID NULL,
  diff JSONB NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_object_versions_record ON object_versions(record_id);

-- 3) GRAPH
CREATE TABLE IF NOT EXISTS object_relations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  source_id UUID NOT NULL,
  target_id UUID NOT NULL,
  rel_type TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  CONSTRAINT uq_src_tgt_type UNIQUE (source_id, target_id, rel_type)
);

-- 4) I18N
CREATE TABLE IF NOT EXISTS localized_string (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  lsid TEXT NOT NULL UNIQUE,
  translations JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- 5) SECURITY (RBAC / ABAC)
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  external_id TEXT UNIQUE,
  email TEXT UNIQUE,
  display_name TEXT,
  created_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS roles (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS permissions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS role_permissions (
  role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
  PRIMARY KEY(role_id, permission_id)
);
CREATE TABLE IF NOT EXISTS user_roles (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  PRIMARY KEY(user_id, role_id)
);
CREATE TABLE IF NOT EXISTS policies (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL UNIQUE,
  type TEXT NOT NULL,               -- "RBAC" | "ABAC"
  condition TEXT DEFAULT NULL,
  effect TEXT NOT NULL DEFAULT 'allow'
);
CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ts TIMESTAMP NOT NULL DEFAULT now(),
  actor UUID NULL,
  action TEXT NOT NULL,
  object_name TEXT NULL,
  record_id UUID NULL,
  meta JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- 6) SCHEDULER
CREATE TABLE IF NOT EXISTS scheduled_jobs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  job_key TEXT NOT NULL UNIQUE,
  enabled BOOLEAN NOT NULL DEFAULT true,
  schedule JSONB NOT NULL,
  action JSONB NOT NULL,
  concurrency TEXT NOT NULL DEFAULT 'allow',
  retry JSONB NOT NULL DEFAULT '{"max":3,"backoff_sec":60}'::jsonb,
  catchup_policy TEXT NOT NULL DEFAULT 'run_missed_on_startup',
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS job_runs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  job_id UUID NOT NULL REFERENCES scheduled_jobs(id) ON DELETE CASCADE,
  planned_at TIMESTAMP NOT NULL,
  started_at TIMESTAMP NULL,
  finished_at TIMESTAMP NULL,
  status TEXT NOT NULL,
  attempt INT NOT NULL DEFAULT 1,
  output JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- 7) INDEXES de base
CREATE INDEX IF NOT EXISTS idx_records_obj ON records(object_name);
CREATE INDEX IF NOT EXISTS idx_records_number ON records(number);
CREATE INDEX IF NOT EXISTS idx_records_data_gin ON records USING GIN (data jsonb_path_ops);
SQL

  cat > ops/sql/010_guards.sql <<'SQL'
CREATE OR REPLACE FUNCTION enforce_object_name()
RETURNS trigger AS $$
BEGIN
  IF NEW.name !~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'Invalid object name %, expected domain.object in snake_case', NEW.name;
  END IF;
  IF split_part(NEW.name,'.',1) = 'core' AND NEW.parent_name IS DISTINCT FROM 'core.work' THEN
    NEW.parent_name := 'core.work';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sys_db_object_name ON sys_db_object;
CREATE TRIGGER trg_sys_db_object_name
BEFORE INSERT OR UPDATE ON sys_db_object
FOR EACH ROW EXECUTE PROCEDURE enforce_object_name();

CREATE OR REPLACE FUNCTION enforce_field_name()
RETURNS trigger AS $$
BEGIN
  IF NEW.name !~ '^[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'Invalid field name %', NEW.name;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sys_dictionary_name ON sys_dictionary;
CREATE TRIGGER trg_sys_dictionary_name
BEFORE INSERT OR UPDATE ON sys_dictionary
FOR EACH ROW EXECUTE PROCEDURE enforce_field_name();
SQL

  cat > ops/sql/020_seed_meta.sql <<'SQL'
-- Objets
INSERT INTO sys_db_object(name,label,parent_name) VALUES
('core.work','{"fr":"Travail","en":"Work"}','core.work')
ON CONFLICT (name) DO NOTHING;

INSERT INTO sys_db_object(name,label,parent_name) VALUES
('itsm.incident','{"fr":"Incident","en":"Incident"}','core.work'),
('itsm.request','{"fr":"Demande","en":"Request"}','core.work'),
('asset.server','{"fr":"Serveur","en":"Server"}','core.work'),
('asset.database','{"fr":"Base de données","en":"Database"}','core.work')
ON CONFLICT (name) DO NOTHING;

-- Champs communs core.work
INSERT INTO sys_dictionary(object_name,name,type,label,required,settings) VALUES
('core.work','number','string','{"fr":"Numéro","en":"Number"}',true,'{}'),
('core.work','title','string','{"fr":"Titre","en":"Title"}',true,'{}'),
('core.work','state','enum','{"fr":"État","en":"State"}',true,'{"enum":["open","in_progress","resolved","closed"]}'),
('core.work','priority','enum','{"fr":"Priorité","en":"Priority"}',true,'{"enum":["p1","p2","p3","p4"]}'),
('core.work','requested_by_id','ref','{"fr":"Demandeur","en":"Requested by"}',false,'{"ref":"users"}'),
('core.work','assigned_to_id','ref','{"fr":"Assigné à","en":"Assigned to"}',false,'{"ref":"users"}'),
('core.work','assignment_group_id','string','{"fr":"Groupe d''affectation","en":"Assignment group"}',false,'{}'),
('core.work','due_at','datetime','{"fr":"Échéance","en":"Due at"}',false,'{}'),
('core.work','tags','array_string','{"fr":"Tags","en":"Tags"}',false,'{}'),
('core.work','data','json','{"fr":"Données","en":"Data"}',false,'{}')
ON CONFLICT DO NOTHING;

-- Spécifiques incident
INSERT INTO sys_dictionary(object_name,name,type,label,required,settings) VALUES
('itsm.incident','impact','enum','{"fr":"Impact","en":"Impact"}',true,'{"enum":["low","medium","high"]}'),
('itsm.incident','urgency','enum','{"fr":"Urgence","en":"Urgency"}',true,'{"enum":["low","medium","high"]}')
ON CONFLICT DO NOTHING;

-- Spécifiques request
INSERT INTO sys_dictionary(object_name,name,type,label,required,settings) VALUES
('itsm.request','category','enum','{"fr":"Catégorie","en":"Category"}',true,'{"enum":["access","hardware","software","other"]}')
ON CONFLICT DO NOTHING;

-- Spécifiques CI
INSERT INTO sys_dictionary(object_name,name,type,label,required,settings) VALUES
('asset.server','hostname','string','{"fr":"Nom d''hôte","en":"Hostname"}',true,'{}'),
('asset.server','ip_address','string','{"fr":"Adresse IP","en":"IP address"}',true,'{}'),
('asset.database','engine','enum','{"fr":"Moteur","en":"Engine"}',true,'{"enum":["postgresql","mysql","mongodb","other"]}'),
('asset.database','version','string','{"fr":"Version","en":"Version"}',false,'{}')
ON CONFLICT DO NOTHING;
SQL

  cat > ops/sql/030_seed_i18n.sql <<'SQL'
INSERT INTO localized_string(lsid, translations) VALUES
('state.open','{"fr":"Ouvert","en":"Open","de":"Offen"}'),
('state.in_progress','{"fr":"En cours","en":"In progress","de":"In Bearbeitung"}'),
('state.resolved','{"fr":"Résolu","en":"Resolved","de":"Gelöst"}'),
('state.closed','{"fr":"Fermé","en":"Closed","de":"Geschlossen"}'),
('priority.p1','{"fr":"Très haute","en":"Critical","de":"Kritisch"}'),
('priority.p2','{"fr":"Haute","en":"High","de":"Hoch"}'),
('priority.p3','{"fr":"Moyenne","en":"Medium","de":"Mittel"}'),
('priority.p4','{"fr":"Basse","en":"Low","de":"Niedrig"}')
ON CONFLICT DO NOTHING;
SQL

  cat > ops/sql/040_security.sql <<'SQL'
-- Permissions
INSERT INTO permissions(name) VALUES
('records.read'),('records.write'),('records.delete'),
('security.read'),('security.write'),
('scheduler.read'),('scheduler.write')
ON CONFLICT DO NOTHING;

-- Rôles + mapping de permissions
WITH r AS (
  INSERT INTO roles(name) VALUES ('admin'),('editor'),('viewer')
  ON CONFLICT (name) DO NOTHING
  RETURNING id,name
)
INSERT INTO role_permissions(role_id, permission_id)
SELECT r.id, p.id FROM r
JOIN permissions p ON (
  (r.name='admin') OR
  (r.name='editor' AND p.name IN ('records.read','records.write','scheduler.read','scheduler.write')) OR
  (r.name='viewer' AND p.name IN ('records.read','scheduler.read'))
)
ON CONFLICT DO NOTHING;

-- Policy ABAC d'exemple
INSERT INTO policies(name,type,condition,effect) VALUES
('access_own_records','ABAC','record.owner_id == user.id','allow')
ON CONFLICT DO NOTHING;
SQL

  cat > ops/sql/050_scheduler.sql <<'SQL'
INSERT INTO scheduled_jobs(job_key,enabled,schedule,action,concurrency,retry,catchup_policy)
VALUES
('daily_cleanup', true,
 '{"kind":"cron","expr":"0 3 * * *","timezone":"Europe/Zurich"}',
 '{"kind":"task","ref":"maintenance.cleanup"}',
 'skip_if_running', '{"max":3,"backoff_sec":60}', 'run_missed_on_startup'),
('rebuild_embeddings', true,
 '{"kind":"cron","expr":"30 2 * * 1","timezone":"Europe/Zurich"}',
 '{"kind":"task","ref":"i18n.rebuild_embeddings"}',
 'allow', '{"max":5,"backoff_sec":120}', 'skip')
ON CONFLICT (job_key) DO NOTHING;
SQL

  cat > ops/sql/060_indexes.sql <<'SQL'
CREATE INDEX IF NOT EXISTS idx_records_data_number ON records ((data->>'number'));
CREATE INDEX IF NOT EXISTS idx_records_owner ON records ((data->>'owner_id'));
CREATE INDEX IF NOT EXISTS idx_relations_src ON object_relations(source_id);
CREATE INDEX IF NOT EXISTS idx_relations_tgt ON object_relations(target_id);
SQL

  # Seed i18n étendu (50) + script embeddings
  cat > ops/sql/031_seed_i18n_full.sql <<'SQL'
INSERT INTO localized_string(lsid, translations) VALUES
('app.title','{"fr": "Titre", "en": "Title", "de": "Titel", "it": "Titolo", "es": "Título"}'::jsonb),
('app.description','{"fr": "Description", "en": "Description", "de": "Beschreibung", "it": "Descrizione", "es": "Descripción"}'::jsonb),
('action.create','{"fr": "Créer", "en": "Create", "de": "Erstellen", "it": "Creare", "es": "Crear"}'::jsonb),
('action.read','{"fr": "Lire", "en": "Read", "de": "Lesen", "it": "Leggere", "es": "Leer"}'::jsonb),
('action.update','{"fr": "Mettre à jour", "en": "Update", "de": "Aktualisieren", "it": "Aggiornare", "es": "Actualizar"}'::jsonb),
('action.delete','{"fr": "Supprimer", "en": "Delete", "de": "Löschen", "it": "Eliminare", "es": "Eliminar"}'::jsonb),
('action.save','{"fr": "Enregistrer", "en": "Save", "de": "Speichern", "it": "Salvare", "es": "Guardar"}'::jsonb),
('action.cancel','{"fr": "Annuler", "en": "Cancel", "de": "Abbrechen", "it": "Annulla", "es": "Cancelar"}'::jsonb),
('action.search','{"fr": "Rechercher", "en": "Search", "de": "Suchen", "it": "Cerca", "es": "Buscar"}'::jsonb),
('action.filter','{"fr": "Filtrer", "en": "Filter", "de": "Filtern", "it": "Filtra", "es": "Filtrar"}'::jsonb),
('action.sort','{"fr": "Trier", "en": "Sort", "de": "Sortieren", "it": "Ordina", "es": "Ordenar"}'::jsonb),
('action.upload','{"fr": "Téléverser", "en": "Upload", "de": "Hochladen", "it": "Caricare", "es": "Subir"}'::jsonb),
('action.download','{"fr": "Télécharger", "en": "Download", "de": "Herunterladen", "it": "Scaricare", "es": "Descargar"}'::jsonb),
('action.attach','{"fr": "Joindre", "en": "Attach", "de": "Anhängen", "it": "Allegare", "es": "Adjuntar"}'::jsonb),
('action.comment','{"fr": "Commenter", "en": "Comment", "de": "Kommentieren", "it": "Commentare", "es": "Comentar"}'::jsonb),
('common.ok','{"fr": "OK", "en": "OK", "de": "OK", "it": "OK", "es": "OK"}'::jsonb),
('common.yes','{"fr": "Oui", "en": "Yes", "de": "Ja", "it": "Sì", "es": "Sí"}'::jsonb),
('common.no','{"fr": "Non", "en": "No", "de": "Nein", "it": "No", "es": "No"}'::jsonb),
('status.open','{"fr": "Ouvert", "en": "Open", "de": "Offen", "it": "Aperto", "es": "Abierto"}'::jsonb),
('status.in_progress','{"fr": "En cours", "en": "In progress", "de": "In Bearbeitung", "it": "In corso", "es": "En progreso"}'::jsonb),
('status.resolved','{"fr": "Résolu", "en": "Resolved", "de": "Gelöst", "it": "Risolto", "es": "Resuelto"}'::jsonb),
('status.closed','{"fr": "Fermé", "en": "Closed", "de": "Geschlossen", "it": "Chiuso", "es": "Cerrado"}'::jsonb),
('priority.critical','{"fr": "Critique", "en": "Critical", "de": "Kritisch", "it": "Critico", "es": "Crítico"}'::jsonb),
('priority.high','{"fr": "Haute", "en": "High", "de": "Hoch", "it": "Alta", "es": "Alta"}'::jsonb),
('priority.medium','{"fr": "Moyenne", "en": "Medium", "de": "Mittel", "it": "Media", "es": "Media"}'::jsonb),
('priority.low','{"fr": "Basse", "en": "Low", "de": "Niedrig", "it": "Bassa", "es": "Baja"}'::jsonb),
('impact.low','{"fr": "Faible", "en": "Low", "de": "Gering", "it": "Basso", "es": "Bajo"}'::jsonb),
('impact.medium','{"fr": "Moyen", "en": "Medium", "de": "Mittel", "it": "Medio", "es": "Medio"}'::jsonb),
('impact.high','{"fr": "Élevé", "en": "High", "de": "Hoch", "it": "Alto", "es": "Alto"}'::jsonb),
('urgency.low','{"fr": "Faible", "en": "Low", "de": "Gering", "it": "Bassa", "es": "Baja"}'::jsonb),
('urgency.medium','{"fr": "Moyenne", "en": "Medium", "de": "Mittel", "it": "Media", "es": "Media"}'::jsonb),
('urgency.high','{"fr": "Élevée", "en": "High", "de": "Hoch", "it": "Alta", "es": "Alta"}'::jsonb),
('color.red','{"fr": "Rouge", "en": "Red", "de": "Rot", "it": "Rosso", "es": "Rojo"}'::jsonb),
('color.green','{"fr": "Vert", "en": "Green", "de": "Grün", "it": "Verde", "es": "Verde"}'::jsonb),
('color.blue','{"fr": "Bleu", "en": "Blue", "de": "Blau", "it": "Blu", "es": "Azul"}'::jsonb),
('color.yellow','{"fr": "Jaune", "en": "Yellow", "de": "Gelb", "it": "Giallo", "es": "Amarillo"}'::jsonb),
('color.black','{"fr": "Noir", "en": "Black", "de": "Schwarz", "it": "Nero", "es": "Negro"}'::jsonb),
('color.white','{"fr": "Blanc", "en": "White", "de": "Weiß", "it": "Bianco", "es": "Blanco"}'::jsonb),
('it.server','{"fr": "Serveur", "en": "Server", "de": "Server", "it": "Server", "es": "Servidor"}'::jsonb),
('it.database','{"fr": "Base de données", "en": "Database", "de": "Datenbank", "it": "Database", "es": "Base de datos"}'::jsonb),
('it.network','{"fr": "Réseau", "en": "Network", "de": "Netzwerk", "it": "Rete", "es": "Red"}'::jsonb),
('it.user','{"fr": "Utilisateur", "en": "User", "de": "Benutzer", "it": "Utente", "es": "Usuario"}'::jsonb),
('it.group','{"fr": "Groupe", "en": "Group", "de": "Gruppe", "it": "Gruppo", "es": "Grupo"}'::jsonb),
('it.settings','{"fr": "Paramètres", "en": "Settings", "de": "Einstellungen", "it": "Impostazioni", "es": "Ajustes"}'::jsonb),
('log.error','{"fr": "Erreur", "en": "Error", "de": "Fehler", "it": "Errore", "es": "Error"}'::jsonb),
('log.warning','{"fr": "Avertissement", "en": "Warning", "de": "Warnung", "it": "Avviso", "es": "Advertencia"}'::jsonb),
('log.info','{"fr": "Information", "en": "Info", "de": "Info", "it": "Informazione", "es": "Información"}'::jsonb),
('process.start','{"fr": "Démarrer", "en": "Start", "de": "Starten", "it": "Avviare", "es": "Iniciar"}'::jsonb),
('process.stop','{"fr": "Arrêter", "en": "Stop", "de": "Stoppen", "it": "Arrestare", "es": "Detener"}'::jsonb),
('process.restart','{"fr": "Redémarrer", "en": "Restart", "de": "Neustarten", "it": "Riavviare", "es": "Reiniciar"}'::jsonb)
ON CONFLICT (lsid) DO NOTHING;
SQL

  cat > ops/i18n/seed_50.json <<'JSON'
[{"lsid":"app.title","translations":{"fr":"Titre","en":"Title","de":"Titel","it":"Titolo","es":"Título"}},
{"lsid":"app.description","translations":{"fr":"Description","en":"Description","de":"Beschreibung","it":"Descrizione","es":"Descripción"}},
{"lsid":"action.create","translations":{"fr":"Créer","en":"Create","de":"Erstellen","it":"Creare","es":"Crear"}},
{"lsid":"action.read","translations":{"fr":"Lire","en":"Read","de":"Lesen","it":"Leggere","es":"Leer"}},
{"lsid":"action.update","translations":{"fr":"Mettre à jour","en":"Update","de":"Aktualisieren","it":"Aggiornare","es":"Actualizar"}},
{"lsid":"action.delete","translations":{"fr":"Supprimer","en":"Delete","de":"Löschen","it":"Eliminare","es":"Eliminar"}},
{"lsid":"action.save","translations":{"fr":"Enregistrer","en":"Save","de":"Speichern","it":"Salvare","es":"Guardar"}},
{"lsid":"action.cancel","translations":{"fr":"Annuler","en":"Cancel","de":"Abbrechen","it":"Annulla","es":"Cancelar"}},
{"lsid":"action.search","translations":{"fr":"Rechercher","en":"Search","de":"Suchen","it":"Cerca","es":"Buscar"}},
{"lsid":"action.filter","translations":{"fr":"Filtrer","en":"Filter","de":"Filtern","it":"Filtra","es":"Filtrar"}},
{"lsid":"action.sort","translations":{"fr":"Trier","en":"Sort","de":"Sortieren","it":"Ordina","es":"Ordenar"}},
{"lsid":"action.upload","translations":{"fr":"Téléverser","en":"Upload","de":"Hochladen","it":"Caricare","es":"Subir"}},
{"lsid":"action.download","translations":{"fr":"Télécharger","en":"Download","de":"Herunterladen","it":"Scaricare","es":"Descargar"}},
{"lsid":"action.attach","translations":{"fr":"Joindre","en":"Attach","de":"Anhängen","it":"Allegare","es":"Adjuntar"}},
{"lsid":"action.comment","translations":{"fr":"Commenter","en":"Comment","de":"Kommentieren","it":"Commentare","es":"Comentar"}},
{"lsid":"common.ok","translations":{"fr":"OK","en":"OK","de":"OK","it":"OK","es":"OK"}},
{"lsid":"common.yes","translations":{"fr":"Oui","en":"Yes","de":"Ja","it":"Sì","es":"Sí"}},
{"lsid":"common.no","translations":{"fr":"Non","en":"No","de":"Nein","it":"No","es":"No"}},
{"lsid":"status.open","translations":{"fr":"Ouvert","en":"Open","de":"Offen","it":"Aperto","es":"Abierto"}},
{"lsid":"status.in_progress","translations":{"fr":"En cours","en":"In progress","de":"In Bearbeitung","it":"In corso","es":"En progreso"}},
{"lsid":"status.resolved","translations":{"fr":"Résolu","en":"Resolved","de":"Gelöst","it":"Risolto","es":"Resuelto"}},
{"lsid":"status.closed","translations":{"fr":"Fermé","en":"Closed","de":"Geschlossen","it":"Chiuso","es":"Cerrado"}},
{"lsid":"priority.critical","translations":{"fr":"Critique","en":"Critical","de":"Kritisch","it":"Critico","es":"Crítico"}},
{"lsid":"priority.high","translations":{"fr":"Haute","en":"High","de":"Hoch","it":"Alta","es":"Alta"}},
{"lsid":"priority.medium","translations":{"fr":"Moyenne","en":"Medium","de":"Mittel","it":"Media","es":"Media"}},
{"lsid":"priority.low","translations":{"fr":"Basse","en":"Low","de":"Niedrig","it":"Bassa","es":"Baja"}},
{"lsid":"impact.low","translations":{"fr":"Faible","en":"Low","de":"Gering","it":"Basso","es":"Bajo"}},
{"lsid":"impact.medium","translations":{"fr":"Moyen","en":"Medium","de":"Mittel","it":"Medio","es":"Medio"}},
{"lsid":"impact.high","translations":{"fr":"Élevé","en":"High","de":"Hoch","it":"Alto","es":"Alto"}},
{"lsid":"urgency.low","translations":{"fr":"Faible","en":"Low","de":"Gering","it":"Bassa","es":"Baja"}},
{"lsid":"urgency.medium","translations":{"fr":"Moyenne","en":"Medium","de":"Mittel","it":"Media","es":"Media"}},
{"lsid":"urgency.high","translations":{"fr":"Élevée","en":"High","de":"Hoch","it":"Alta","es":"Alta"}},
{"lsid":"color.red","translations":{"fr":"Rouge","en":"Red","de":"Rot","it":"Rosso","es":"Rojo"}},
{"lsid":"color.green","translations":{"fr":"Vert","en":"Green","de":"Grün","it":"Verde","es":"Verde"}},
{"lsid":"color.blue","translations":{"fr":"Bleu","en":"Blue","de":"Blau","it":"Blu","es":"Azul"}},
{"lsid":"color.yellow","translations":{"fr":"Jaune","en":"Yellow","de":"Gelb","it":"Giallo","es":"Amarillo"}},
{"lsid":"color.black","translations":{"fr":"Noir","en":"Black","de":"Schwarz","it":"Nero","es":"Negro"}},
{"lsid":"color.white","translations":{"fr":"Blanc","en":"White","de":"Weiß","it":"Bianco","es":"Blanco"}},
{"lsid":"it.server","translations":{"fr":"Serveur","en":"Server","de":"Server","it":"Server","es":"Servidor"}},
{"lsid":"it.database","translations":{"fr":"Base de données","en":"Database","de":"Datenbank","it":"Database","es":"Base de datos"}},
{"lsid":"it.network","translations":{"fr":"Réseau","en":"Network","de":"Netzwerk","it":"Rete","es":"Red"}},
{"lsid":"it.user","translations":{"fr":"Utilisateur","en":"User","de":"Benutzer","it":"Utente","es":"Usuario"}},
{"lsid":"it.group","translations":{"fr":"Groupe","en":"Group","de":"Gruppe","it":"Gruppo","es":"Grupo"}},
{"lsid":"it.settings","translations":{"fr":"Paramètres","en":"Settings","de":"Einstellungen","it":"Impostazioni","es":"Ajustes"}},
{"lsid":"log.error","translations":{"fr":"Erreur","en":"Error","de":"Fehler","it":"Errore","es":"Error"}},
{"lsid":"log.warning","translations":{"fr":"Avertissement","en":"Warning","de":"Warnung","it":"Avviso","es":"Advertencia"}},
{"lsid":"log.info","translations":{"fr":"Information","en":"Info","de":"Info","it":"Informazione","es":"Información"}},
{"lsid":"process.start","translations":{"fr":"Démarrer","en":"Start","de":"Starten","it":"Avviare","es":"Iniciar"}},
{"lsid":"process.stop","translations":{"fr":"Arrêter","en":"Stop","de":"Stoppen","it":"Arrestare","es":"Detener"}},
{"lsid":"process.restart","translations":{"fr":"Redémarrer","en":"Restart","de":"Neustarten","it":"Riavviare","es":"Reiniciar"}}]
JSON

  cat > ops/i18n/embed_seed.py <<'PY'
import json, os, requests
QURL=os.getenv("QDRANT_URL","http://qdrant:6333")
COL=os.getenv("QDRANT_COLLECTION","i18n_embeddings")
PATH=os.getenv("SEED_PATH","/work/seed_50.json")
MODEL=os.getenv("MODEL_NAME","sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2")
from sentence_transformers import SentenceTransformer
items=json.load(open(PATH,"r",encoding="utf-8"))
texts=[]; ids=[]; payloads=[]
for i,it in enumerate(items):
  l=it["lsid"]; tr=it["translations"]; txt=f"{l} :: "+" | ".join([tr.get(k,"") for k in ("fr","en","de","it","es")])
  texts.append(txt); ids.append(i+1); payloads.append({"lsid":l,"translations":tr})
vecs=SentenceTransformer(MODEL).encode(texts, normalize_embeddings=True).tolist()
points=[{"id":pid,"vector":v,"payload":pl} for pid,v,pl in zip(ids,vecs,payloads)]
r=requests.put(f"{QURL}/collections/{COL}/points?wait=true", json={"points":points}, timeout=300); r.raise_for_status()
print("Upserted:",len(points))
PY
}

step_infra_up() {
  log "Démarrage de l'infrastructure (Docker Compose)"
  ( cd infra/compose && $DOCKER compose up -d )
  ( cd infra/compose && $DOCKER compose ps )
}

step_db() {
  log "Attente Postgres prêt (pg_isready)"
  wait_container postgres 180
  local PG_CID; PG_CID="$($DOCKER compose -f "$compose_file" ps -q postgres)"
  [ -n "$PG_CID" ] || die "postgres introuvable"

  log "Application schéma + seeds SQL"
  $DOCKER exec -i "$PG_CID" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' < ops/sql/000_init.sql
  $DOCKER exec -i "$PG_CID" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' < ops/sql/010_guards.sql
  $DOCKER exec -i "$PG_CID" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' < ops/sql/020_seed_meta.sql
  $DOCKER exec -i "$PG_CID" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' < ops/sql/030_seed_i18n.sql
  $DOCKER exec -i "$PG_CID" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' < ops/sql/031_seed_i18n_full.sql
  $DOCKER exec -i "$PG_CID" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' < ops/sql/040_security.sql
  $DOCKER exec -i "$PG_CID" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' < ops/sql/050_scheduler.sql
  $DOCKER exec -i "$PG_CID" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' < ops/sql/060_indexes.sql
}

step_qdrant_and_embeddings() {
  log "Attente Qdrant HTTP sur l'hôte"
  wait_http "http://localhost:6333/collections" 180 || die "Qdrant indisponible"

  # Déterminer dynamiquement la dimension du modèle d'embedding
  log "Détection de la dimension d'embedding du modèle: ${EMBED_MODEL}"
  local DIM
  DIM="$($DOCKER run --rm \
    -e MODEL_NAME="${EMBED_MODEL}" python:3.12-slim sh -lc \
    'PIP_DISABLE_PIP_VERSION_CHECK=1 pip install -q "sentence-transformers>=2.7.0" >/dev/null 2>&1; \
     python - <<PY
import os
from sentence_transformers import SentenceTransformer
m = SentenceTransformer(os.getenv("MODEL_NAME"))
print(m.get_sentence_embedding_dimension())
PY')"
  DIM="$(echo "$DIM" | tr -d '\r\n')"
  [ -n "$DIM" ] || die "Impossible de détecter la dimension du modèle"
  log "Dimension détectée: ${DIM}"

  # Vérifier la collection existante et recréer si taille différente
  local EXIST
  EXIST="$(curl -s "http://localhost:6333/collections/${QDRANT_COLLECTION}" | jq -r '.result.config.params.vectors.size // empty')"
  if [ -n "$EXIST" ] && [ "$EXIST" != "$DIM" ]; then
    log "Collection existante avec taille ${EXIST} ≠ ${DIM} → suppression"
    curl -s -X DELETE "http://localhost:6333/collections/${QDRANT_COLLECTION}" >/dev/null || true
  fi

  log "Création/validation de la collection Qdrant (size=${DIM})"
  curl -s -X PUT "http://localhost:6333/collections/${QDRANT_COLLECTION}" \
    -H "Content-Type: application/json" \
    -d "{\"vectors\":{\"size\":${DIM},\"distance\":\"Cosine\"},\"optimizers_config\":{\"default_segment_number\":2}}" | jq . || true

  log "Indexation des embeddings i18n (conteneur Python → URL interne qdrant:6333)"
  local NET; NET="$(compose_network)"
  $DOCKER run --rm --network "$NET" \
    -e QDRANT_URL="http://qdrant:6333" \
    -e QDRANT_COLLECTION="${QDRANT_COLLECTION}" \
    -e SEED_PATH="/work/seed_50.json" \
    -e MODEL_NAME="${EMBED_MODEL}" \
    -v "${TARGET_DIR}/ops/i18n:/work" python:3.12-slim sh -lc \
    'PIP_DISABLE_PIP_VERSION_CHECK=1 pip install --no-cache-dir "sentence-transformers>=2.7.0" requests && python /work/embed_seed.py'
}

step_minio() {
  log "Configuration MinIO (bucket + policy lecture/écriture + user dev)"
  cat > ops/minio/bucket-policy.json <<'JSON'
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::souveratech"]},
  {"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::souveratech/*"]}
]}
JSON
  local NET; NET="$(compose_network)"
  $DOCKER run --rm --network "$NET" -v "${TARGET_DIR}/ops/minio:/work" \
    --entrypoint=/bin/sh "minio/mc:${MC_VERSION}" -c "\
    mc alias set local http://minio:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} >/dev/null 2>&1; \
    mc mb -p local/souveratech || true; \
    mc anonymous set-json /work/bucket-policy.json local/souveratech || true; \
    mc ls local/souveratech"
}

step_keycloak() {
  log "Attente Keycloak HTTP"
  wait_http "http://localhost:8088/realms/master/.well-known/openid-configuration" 240 || die "Keycloak indisponible"

  log "Création realm + clients (ui, api) et récupération du secret"
  local KC_TOKEN
  KC_TOKEN="$(curl -s \
    -d "client_id=admin-cli" \
    -d "username=${KC_BOOTSTRAP_ADMIN_USERNAME}" \
    -d "password=${KC_BOOTSTRAP_ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    http://localhost:8088/realms/master/protocol/openid-connect/token | jq -r .access_token)"
  [ -n "$KC_TOKEN" ] || die "Impossible d'obtenir le token admin Keycloak"

  curl -s -X POST "http://localhost:8088/admin/realms" \
    -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"realm\":\"${PROJECT_NAME}\",\"enabled\":true}" >/dev/null || true

  curl -s -X POST "http://localhost:8088/admin/realms/${PROJECT_NAME}/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" \
    -d '{"clientId":"ui","publicClient":true,"directAccessGrantsEnabled":true,"redirectUris":["*"],"webOrigins":["*"]}' >/dev/null || true

  curl -s -X POST "http://localhost:8088/admin/realms/${PROJECT_NAME}/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"clientId\":\"${OIDC_CLIENT_ID}\",\"serviceAccountsEnabled\":true,\"publicClient\":false,\"protocol\":\"openid-connect\"}" >/dev/null || true

  local CID SECRET
  CID="$(curl -s -H "Authorization: Bearer ${KC_TOKEN}" "http://localhost:8088/admin/realms/${PROJECT_NAME}/clients" | jq -r '.[] | select(.clientId=="'"${OIDC_CLIENT_ID}"'") | .id')"
  SECRET="$(curl -s -H "Authorization: Bearer ${KC_TOKEN}" "http://localhost:8088/admin/realms/${PROJECT_NAME}/clients/${CID}/client-secret" | jq -r .value)"

  if [ -n "$SECRET" ] && [ "$OIDC_CLIENT_SECRET" = "REPLACE_WITH_SECRET" ]; then
    log "Injection du secret OIDC dans .env.app et infra/compose/.env"
    sed -i "s|^OIDC_CLIENT_SECRET=.*|OIDC_CLIENT_SECRET=${SECRET}|" ".env.app"
    sed -i "s|^OIDC_CLIENT_SECRET=.*|OIDC_CLIENT_SECRET=${SECRET}|" "infra/compose/.env"
    ( cd infra/compose && $DOCKER compose up -d oauth2-proxy ) || true
  fi
}

step_os_index() {
  log "Attente OpenSearch HTTP"
  # Auth-aware wait for OpenSearch (expects HTTP 200 with valid credentials)
  t=0
  while true; do
    code="$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" http://localhost:9200 || echo 000)"
    if [ "$code" = "200" ]; then break; fi
    sleep 2; t=$((t+2)); [ "$t" -ge 240 ] && die "OpenSearch indisponible"
  done
  log "Création index OpenSearch 'souveratech-logs'"
  curl -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" -s -X PUT "http://localhost:9200/souveratech-logs" \
    -H "Content-Type: application/json" -d '{
      "settings":{"index":{"number_of_shards":1,"number_of_replicas":0}},
      "mappings":{"properties":{
        "ts":{"type":"date"},
        "level":{"type":"keyword"},
        "service":{"type":"keyword"},
        "message":{"type":"text"},
        "meta":{"type":"object","enabled":true}
      }}
    }' | jq .
}

step_apps_build_up() {
  log "Build et lancement des microservices + UI"
  ( cd infra/compose && $DOCKER compose build core-meta scheduler core-security core-i18n core-versioning core-graph notifications etl discovery ui || $DOCKER compose build )
  ( cd infra/compose && $DOCKER compose up -d core-meta scheduler core-security core-i18n core-versioning core-graph notifications etl discovery ui )
  ( cd infra/compose && $DOCKER compose ps )
}

step_tests() {
  log "[Tests] Vérifications rapides"
  set +e
  curl -fsS http://localhost:9001/ >/dev/null && echo "MinIO OK" || echo "MinIO NOK"
  curl -fsS -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" http://localhost:9200 >/dev/null && echo "OpenSearch OK" || echo "OpenSearch NOK"
  curl -fsS http://localhost:8088/realms/master/.well-known/openid-configuration >/dev/null && echo "Keycloak OK" || echo "Keycloak NOK"
  curl -fsS http://localhost:9090/metrics >/dev/null && echo "Prometheus OK" || echo "Prometheus NOK"
  curl -fsS http://localhost:3000/ >/dev/null && echo "Grafana OK" || echo "Grafana NOK"
  curl -fsS http://localhost:11434/api/tags >/dev/null && echo "Ollama OK" || echo "Ollama NOK"
  curl -fsS http://localhost:6333/collections >/dev/null && echo "Qdrant OK" || echo "Qdrant NOK"
  curl -fsS http://localhost:18081/healthz >/dev/null && echo "core-meta OK" || echo "core-meta NOK"
  curl -fsS http://localhost:18082/healthz >/dev/null && echo "scheduler OK" || echo "scheduler NOK"
  curl -fsS http://localhost:8085/ >/dev/null && echo "UI OK" || echo "UI NOK"
  set -e
}


step_reset() {
  log "Reset: docker compose down -v, dann kompletter Neuaufbau"
  step_clean
  run_all
}

step_clean() { log "Arrêt + purge volumes"; ( cd infra/compose && $DOCKER compose down -v || true ); }
step_nuke() { step_clean; log "Suppression fichiers"; rm -rf "${TARGET_DIR:?}/infra" "${TARGET_DIR:?}/ops" "${TARGET_DIR:?}/apps" "${TARGET_DIR:?}/.env.app" || true; }

# ---------- Orchestrateur ----------
usage() {
  cat <<EOF
Usage: $0 [commande]
Commandes:
  setup-host    Installe les prérequis OS (Docker, sysctl, swap, timezone)
  files         Génère tous les fichiers (compose, SQL, UI, apps, seeds)
  infra         Démarre l'infra docker compose
  db            Applique le schéma + seeds SQL
  seed          Qdrant + embeddings + MinIO + Keycloak + OpenSearch index
  apps          Build & up des microservices + UI
  test          Tests rapides
  all           files -> infra -> db -> seed -> apps -> test
  clean         docker compose down -v
  reset         clean -> all (Neuaufsetzen ohne Dateien zu löschen)
  nuke          clean + suppression des fichiers générés
Sans commande: exécute setup-host puis all.
EOF
}

run_all() {
  step_scaffold
  step_infra_up
  step_db
  step_qdrant_and_embeddings
  step_minio
  step_keycloak
  step_os_index
  step_apps_build_up
  step_tests
}

main() {
  mkdir -p "${TARGET_DIR}"
  cd "${TARGET_DIR}"

  case "${1:-}" in
    setup-host) step_setup_host ;;
    files) step_scaffold ;;
    infra) step_infra_up ;;
    db) step_db ;;
    seed) step_qdrant_and_embeddings; step_minio; step_keycloak; step_os_index ;;
    apps) step_apps_build_up ;;
    test) step_tests ;;
    reset) step_reset ;;
    clean) step_clean ;;
    nuke) step_nuke ;;
    all) run_all ;;
    "" )
      step_setup_host
      run_all
      ;;
    * ) usage; exit 1 ;;
  esac

  log "Terminé."
}

main "$@"
