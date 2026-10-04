# -f se repite en vez de usar "a:b": con rutas de Windows el ":" choca con la
# unidad del drive y compose lo interpreta como un archivo inexistente.
DC       := docker compose -f docker-compose.yml
DC_OBS   := docker compose -f docker-compose.yml -f compose/obs.yml     --profile obs
DC_FULL  := docker compose -f docker-compose.yml -f compose/full.yml    --profile full
DC_CLU   := docker compose -f docker-compose.yml -f compose/cluster.yml --profile cluster

# No se define SHELL a proposito. El make de Windows (GnuWin32, GNU Make 3.81)
# busca /bin/sh, no lo encuentra y ejecuta las recipes con cmd.exe: si el
# Makefile le fuerza un shell que no existe, todos los targets se rompen.
#
# Las recipes de abajo solo usan docker, asi que funcionan en cmd.exe y en sh.
# Los dos targets que necesitan un shell POSIX (help y verify) lo resuelven
# solos: verify busca el bash de Git con una ruta sin espacios, porque entrecomillar
# un path con espacios en cmd.exe es fragil.
GIT_BASH := $(firstword $(wildcard C:/Progra~1/Git/bin/bash.exe) $(wildcard C:/Progra~2/Git/bin/bash.exe))
VERIFY_SH ?= $(if $(GIT_BASH),"$(GIT_BASH)",sh)

.DEFAULT_GOAL := help
.PHONY: help up down reset logs ps psql psql-pgbouncer obs obs-down full full-down cluster cluster-down verify

help:
	@$(info make up             - infra base y espera a que todo este healthy)
	@$(info make down           - baja todo, conserva los volumenes)
	@$(info make reset          - baja todo y BORRA los volumenes)
	@$(info make logs           - sigue los logs de la infra base)
	@$(info make ps             - estado de los contenedores)
	@$(info make psql           - psql contra PostgreSQL directo (5432), para migraciones)
	@$(info make psql-pgbouncer - psql a traves de PgBouncer (6432), el camino de la app)
	@$(info make obs            - perfil obs: Prometheus, Grafana, Loki, Alloy, OTel)
	@$(info make obs-down       - baja el perfil obs)
	@$(info make full           - perfil full: infra base + la app)
	@$(info make full-down      - baja el perfil full)
	@$(info make cluster        - perfil cluster: Redis Cluster de 6 nodos)
	@$(info make cluster-down   - baja el Redis Cluster)
	@$(info make verify         - corre los criterios de aceptacion de la HU 01.1)
	@$(info ver README.md para el detalle de los perfiles y troubleshooting)
	@:

up: ## Levanta la infra base y espera a que todo esté healthy
	$(DC) up -d --wait

down: ## Baja todo (incluye contenedores de perfiles), conserva los volúmenes
	$(DC) down --remove-orphans

reset: ## Borra los volúmenes: la base de datos arranca vacía
	$(DC) down --remove-orphans -v

logs: ## Sigue los logs de la infra base
	$(DC) logs -f --tail=100

ps: ## Estado de los contenedores
	$(DC) ps

psql: ## psql contra PostgreSQL directo (puerto 5432) - migraciones
	$(DC) exec postgres psql -U app -d tickets

psql-pgbouncer: ## psql contra PgBouncer (puerto 6432) - tráfico de la app
	$(DC) exec pgbouncer psql -h 127.0.0.1 -p 5432 -U app -d tickets

obs: ## Perfil obs: Prometheus, Grafana, Loki, Alloy, OTel
	$(DC_OBS) up -d --wait

obs-down: ## Baja el perfil obs
	$(DC_OBS) down --remove-orphans

full: ## Perfil full: infra base + la app
	$(DC_FULL) up -d --wait

full-down: ## Baja el perfil full
	$(DC_FULL) down --remove-orphans

cluster: ## Perfil cluster: Redis Cluster de 6 nodos
	$(DC_CLU) up -d --wait

cluster-down: ## Baja el Redis Cluster
	$(DC_CLU) down --remove-orphans

verify: ## Corre los criterios de aceptación de la HU 01.1
	$(VERIFY_SH) scripts/verify-ca.sh