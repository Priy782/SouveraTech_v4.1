#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =========================================================
# Souveratech_v3 - make_extra_v2.sh
# Ziel:
# - Keine Änderungen an make.sh
# - Next.js-App "apps/ui-next" NON-INTERACTIVE erstellen
# - Strikt NPM (kein Corepack, kein pnpm) -> vermeidet EACCES
# - Optionale Dockerfile + Compose-Override anlegen
# - Komfort-Commands: ui-next|compose|up|all
# =========================================================

# --- Hilfsfunktionen ---------------------------------------------------------
log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
err() { printf '[%(%H:%M:%S)T] ERROR: %s\n' -1 "$*" >&2; }
die() { err "$*"; exit 1; }

# --- Projektwurzel ermitteln -------------------------------------------------
# Priorität: Git-Root -> Verzeichnis der Scriptdatei -> CWD
resolve_root() {
  local here script_dir git_root
  here="$(pwd)"
  # Pfad der Scriptdatei (auch wenn über Symlink aufgerufen)
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  if git_root="$(cd "$script_dir" && git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$git_root"
  else
    # Wir erwarten die Struktur des Souveratech_v3 Repos:
    # <root>/{apps,infra,packages,...}
    # Falls das Script im Root liegt, passt das.
    printf '%s\n' "$script_dir"
  fi
}
ROOT="$(resolve_root)"
APPS_DIR="$ROOT/apps"
INFRA_COMPOSE_DIR="$ROOT/infra/compose"
UI_NEXT_DIR="$APPS_DIR/ui-next"
EXTRA_COMPOSE="$INFRA_COMPOSE_DIR/docker-compose.extra.yml"

# --- Guards ------------------------------------------------------------------
require_tools() {
  command -v node >/dev/null 2>&1 || die "Node.js ist nicht installiert/in PATH."
  command -v npm  >/dev/null 2>&1 || die "npm ist nicht installiert/in PATH."
}

ensure_layout() {
  mkdir -p "$APPS_DIR"
  mkdir -p "$INFRA_COMPOSE_DIR"
}

# --- Next.js erstellen (non-interactive, npm only) ---------------------------
create_ui_next() {
  require_tools
  ensure_layout

  local target="$UI_NEXT_DIR"
  log "Erzeuge Next.js App unter: $target"
  rm -rf "$target"

  # Non-interactive, reine npm-Erstellung
  npx --yes create-next-app@latest "$target" \
    --use-npm \
    --ts \
    --tailwind \
    --eslint \
    --app \
    --src-dir \
    --import-alias "@/*"

  # Beispielseite überschreiben/anlegen
  mkdir -p "$target/src/app"
  cat > "$target/src/app/page.tsx" <<'TSX'
export default function Page() {
  return (
    <main className="p-10">
      <h1 className="text-2xl font-bold">Hello from ui-next ✅</h1>
      <p className="mt-2 text-sm text-gray-600">Created by make_extra_v2.sh (npm-only, non-interactive)</p>
    </main>
  );
}
TSX

  log "Next.js App erstellt. Lokal starten mit: cd apps/ui-next && npm run dev"
}

# --- Dockerfile für UI (optional) --------------------------------------------
write_ui_next_dockerfile() {
  ensure_layout
  mkdir -p "$UI_NEXT_DIR"
  cat > "$UI_NEXT_DIR/Dockerfile" <<'DOCKER'
# Multi-stage optional (hier einfach gehalten)
FROM node:20-alpine

WORKDIR /app

# Nur die Manifeste zuerst -> effizienteres Caching
COPY package*.json ./

RUN npm ci

# Quellcode kopieren und builden
COPY . ./
RUN npm run build

ENV NODE_ENV=production
EXPOSE 3000
CMD ["npm", "start"]
DOCKER
  log "Dockerfile für ui-next geschrieben: apps/ui-next/Dockerfile"
}

# --- Compose-Override schreiben (optional) -----------------------------------
# Achtung: Pfade sind relativ zur Datei im Ordner infra/compose/
write_compose_override() {
  ensure_layout

  cat > "$EXTRA_COMPOSE" <<'YAML'
# docker-compose.extra.yml
# Extra-Dienste für Souveratech_v3, ohne die Basisdatei zu verändern.
# Aktivierung gezielt via: docker compose -f infra/compose/docker-compose.yml -f infra/compose/docker-compose.extra.yml up -d ui-next
services:
  ui-next:
    build:
      context: ../../apps/ui-next
      dockerfile: Dockerfile
    environment:
      NODE_ENV: production
    ports:
      - "8085:3000"
    depends_on: []
    labels:
      traefik.enable: "true"
      traefik.http.routers.ui-next.rule: PathPrefix(`/`)
      traefik.http.routers.ui-next.entrypoints: web
      traefik.http.services.ui-next.loadbalancer.server.port: "3000"
YAML

  log "Compose-Override geschrieben: $EXTRA_COMPOSE"
}

# --- Hochfahren der UI via Compose ------------------------------------------
compose_up_ui() {
  ensure_layout
  local base="$INFRA_COMPOSE_DIR/docker-compose.yml"
  local extra="$EXTRA_COMPOSE"

  [[ -f "$base" ]] || die "Basis-Compose nicht gefunden: $base"
  [[ -f "$extra" ]] || die "Extra-Compose nicht gefunden: $extra (erst 'compose' ausführen)"

  ( set -x
    docker compose -f "$base" -f "$extra" up -d ui-next
  )
}

# --- Usage -------------------------------------------------------------------
usage() {
  cat <<'USAGE'
make_extra_v2.sh – Zusatzhelfer für Souveratech_v3

Befehle:
  ui-next   – Erstellt Next.js App unter apps/ui-next (npm-only, non-interactive)
  docker    – Schreibt Dockerfile für apps/ui-next
  compose   – Legt infra/compose/docker-compose.extra.yml für ui-next an
  up        – Startet ui-next via docker compose (Base + Extra)
  all       – Führt ui-next, docker, compose und up nacheinander aus

Beispiele:
  ./make_extra_v2.sh ui-next
  ./make_extra_v2.sh docker
  ./make_extra_v2.sh compose
  ./make_extra_v2.sh up
  ./make_extra_v2.sh all
USAGE
}

# --- Main --------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  case "$cmd" in
    ui-next)
      create_ui_next
      ;;
    docker)
      write_ui_next_dockerfile
      ;;
    compose)
      write_compose_override
      ;;
    up)
      compose_up_ui
      ;;
    all)
      create_ui_next
      write_ui_next_dockerfile
      write_compose_override
      compose_up_ui
      ;;
    *)
      usage
      ;;
  esac
  log "Fertig."
}
main "$@"
