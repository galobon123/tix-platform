#!/bin/sh
# Criterios de Aceptacion de la HU 01.1 - Entorno de Desarrollo Local Contenerizado.
# Uso: make verify   (o: sh scripts/verify-ca.sh)
#
# Los CA tienen numeros de documento (docs/02.md, seccion HU 01.1).

# Los comandos de compose son relativos a la raiz del repo.
cd "$(dirname "$0")/.." || exit 1

BASE="docker-compose.yml"
DC="docker compose -f $BASE"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFALLA\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if ! docker info >/dev/null 2>&1; then
  echo "El daemon de Docker no responde. Abri Docker Desktop y volve a correr."
  exit 1
fi

# ---------------------------------------------------------------- CA 5
# Ningun secreto versionado: .env ignorado y .env.example presente.
head_ "CA 5 - Ningun secreto esta versionado"

if [ -f .env.example ]; then
  ok ".env.example existe"
else
  bad ".env.example no existe"
fi

if [ -f .gitignore ] && grep -qx '\.env' .gitignore; then
  ok ".env esta en .gitignore"
else
  bad ".env no esta en .gitignore"
fi

if [ -d .git ]; then
  if git ls-files --error-unmatch .env >/dev/null 2>&1; then
    bad ".env esta trackeado en git"
  else
    ok ".env no esta trackeado en git"
  fi
else
  printf '  --   (no hay repo git inicializado: chequeo de tracking omitido)\n'
fi

# ---------------------------------------------------------------- CA 1
# `up -d --wait` sale con 0 y todos los contenedores quedan healthy.
head_ "CA 1 - up -d --wait termina en exit 0 con todo healthy"

START=$(date +%s)
if $DC up -d --wait; then
  ELAPSED=$(( $(date +%s) - START ))
  ok "docker compose up -d --wait salio con exit 0 (${ELAPSED}s)"
else
  bad "docker compose up -d --wait devolvio un error"
  $DC ps
  echo "  $DC logs --tail=80"
  exit 1
fi

UNHEALTHY=$($DC ps -q | while read -r id; do
  [ -n "$id" ] || continue
  h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}' "$id")
  [ "$h" = "healthy" ] || echo "$h"
done)

if [ -z "$UNHEALTHY" ]; then
  ok "todos los contenedores estan healthy"
else
  bad "contenedores no healthy: $(echo "$UNHEALTHY" | tr '\n' ' ')"
  $DC ps
fi

# ---------------------------------------------------------------- CA 4
# psql funciona contra el Postgres directo (5432) y a traves de PgBouncer (6432).
head_ "CA 4 - psql contra 5432 (directo) y 6432 (PgBouncer)"

if $DC exec -T postgres psql -U app -d tickets -tAc 'select 1' >/dev/null 2>&1; then
  ok "psql directo (5432) responde"
else
  bad "psql directo (5432) fallo"
fi

# La app se pool-ea via pgbouncer: la consulta sale de otro contenedor y entra
# por el pooler, que es el camino real en runtime. El PGPASSWORD se resuelve
# DENTRO del contenedor, que es donde vive la variable de entorno.
#
# El stderr se guarda y se imprime: pgbouncer loguea "login attempt" y nada
# mas cuando la clave no coincide, asi que sin el error de psql el unico
# sintoma es "fallo" y no se sabe por que.
PG_ERR=$(mktemp)
if $DC exec -T postgres sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" psql -h pgbouncer -p 5432 -U app -d tickets -tAc "select 1"' \
     >/dev/null 2>"$PG_ERR"; then
  ok "consulta real a traves de PgBouncer responde"
else
  bad "la consulta a traves de PgBouncer fallo"
  sed 's/^/       /' "$PG_ERR"
  echo "       causa mas probable: la clave que espera pgbouncer no es la del"
  echo "       volumen. pgbouncer se genera desde DATABASE_URL al arrancar, y"
  echo "       postgres solo aplica POSTGRES_PASSWORD cuando el volumen se"
  echo "       inicializa. Cambiar la clave (en .env o por variable de entorno,"
  echo "       que tiene precedencia sobre .env) sin 'make reset' deja el"
  echo "       userlist desfasado. Solucion: make reset && make up"
  $DC logs --tail=20 pgbouncer | sed 's/^/       /'
fi
rm -f "$PG_ERR"

# ---------------------------------------------------------------- CA 2
# Los datos sobreviven a `down` + `up`, y no a `reset`.
head_ "CA 2 - los datos sobreviven a down/up y no a reset"

$DC exec -T postgres psql -U app -d tickets -q \
  -c "create table if not exists _ca_marker(id int primary key, v text)" \
  -c "insert into _ca_marker values (1,'ca-01-1') on conflict do nothing" >/dev/null 2>&1

$DC down >/dev/null 2>&1
if $DC up -d --wait >/dev/null 2>&1; then
  MARKER=$($DC exec -T postgres psql -U app -d tickets -tAc 'select v from _ca_marker where id=1' 2>/dev/null)
  if [ "$MARKER" = "ca-01-1" ]; then
    ok "el marcador sigue presente despues de down + up"
  else
    bad "el marcador se perdio en down + up"
  fi
else
  bad "no se pudo volver a levantar el entorno tras down"
fi

$DC down --remove-orphans -v >/dev/null 2>&1
if $DC up -d --wait >/dev/null 2>&1; then
  LEFT=$($DC exec -T postgres psql -U app -d tickets -tAc "select count(*) from _ca_marker" 2>/dev/null)
  if [ -z "$LEFT" ]; then
    ok "reset borro los volumenes (la tabla ya no existe)"
  else
    bad "reset no borro los volumenes"
  fi
else
  bad "no se pudo levantar el entorno tras reset"
fi

# ---------------------------------------------------------------- CA 3
# Con las imagenes ya descargadas, el entorno queda operativo en < 2 min.
head_ "CA 3 - entorno operativo en menos de 2 minutos (imagenes ya bajadas)"

$DC down --remove-orphans >/dev/null 2>&1
START=$(date +%s)
if $DC up -d --wait >/dev/null 2>&1; then
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$ELAPSED" -lt 120 ]; then
    ok "levantamiento en ${ELAPSED}s (< 120s)"
  else
    bad "levantamiento en ${ELAPSED}s, supera el limite de 120s"
  fi
else
  bad "el levantamiento fallo"
fi

# ---------------------------------------------------------------- resumen
printf '\n\033[1mResumen: %d OK, %d fallas\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1