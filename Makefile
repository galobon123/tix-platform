# -f is repeated instead of using "a:b": with Windows paths the ":" clashes with the
# drive letter and compose interprets it as a nonexistent file.
DC       := docker compose -f docker-compose.yml
DC_OBS   := docker compose -f docker-compose.yml -f compose/obs.yml     --profile obs
DC_FULL  := docker compose -f docker-compose.yml -f compose/full.yml    --profile full
DC_CLU   := docker compose -f docker-compose.yml -f compose/cluster.yml --profile cluster

# SHELL is deliberately not defined. Windows make (GnuWin32, GNU Make 3.81)
# looks for /bin/sh, does not find it and runs the recipes with cmd.exe: if the
# Makefile forces a shell that does not exist, every target breaks.
#
# The recipes below only use docker, so they work both in cmd.exe and in sh.
# The two targets that need a POSIX shell (help and verify) solve it on their own:
# verify looks for Git's bash using a path without spaces, because quoting a path
# with spaces in cmd.exe is fragile.
GIT_BASH := $(firstword $(wildcard C:/Progra~1/Git/bin/bash.exe) $(wildcard C:/Progra~2/Git/bin/bash.exe))
VERIFY_SH ?= $(if $(GIT_BASH),"$(GIT_BASH)",sh)

.DEFAULT_GOAL := help
.PHONY: help up down reset logs ps psql psql-pgbouncer obs obs-down full full-down cluster cluster-down verify

help:
	@$(info make up             - base infra and waits for everything to be healthy)
	@$(info make down           - brings everything down, keeps the volumes)
	@$(info make reset          - brings everything down and DELETES the volumes)
	@$(info make logs           - follows the base infra logs)
	@$(info make ps             - container status)
	@$(info make psql           - psql against the direct PostgreSQL (5432), for migrations)
	@$(info make psql-pgbouncer - psql through PgBouncer (6432), the app path)
	@$(info make obs            - obs profile: Prometheus, Grafana, Loki, Alloy, OTel)
	@$(info make obs-down       - brings the obs profile down)
	@$(info make full           - full profile: base infra + the app)
	@$(info make full-down      - brings the full profile down)
	@$(info make cluster        - cluster profile: 6-node Redis Cluster)
	@$(info make cluster-down   - brings the Redis Cluster down)
	@$(info make verify         - runs the acceptance criteria of HU 01.1)
	@$(info see README.md for profile details and troubleshooting)
	@:

up: ## Brings up the base infra and waits for everything to be healthy
	$(DC) up -d --wait

down: ## Brings everything down (includes profile containers), keeps the volumes
	$(DC) down --remove-orphans

reset: ## Deletes the volumes: the database starts empty
	$(DC) down --remove-orphans -v

logs: ## Follows the base infra logs
	$(DC) logs -f --tail=100

ps: ## Container status
	$(DC) ps

psql: ## psql against the direct PostgreSQL (port 5432) - migrations
	$(DC) exec postgres psql -U app -d tickets

psql-pgbouncer: ## psql against PgBouncer (port 6432) - app traffic
	$(DC) exec pgbouncer psql -h 127.0.0.1 -p 5432 -U app -d tickets

obs: ## obs profile: Prometheus, Grafana, Loki, Alloy, OTel
	$(DC_OBS) up -d --wait

obs-down: ## Brings the obs profile down
	$(DC_OBS) down --remove-orphans

full: ## full profile: base infra + the app
	$(DC_FULL) up -d --wait

full-down: ## Brings the full profile down
	$(DC_FULL) down --remove-orphans

cluster: ## cluster profile: 6-node Redis Cluster
	$(DC_CLU) up -d --wait

cluster-down: ## Brings the Redis Cluster down
	$(DC_CLU) down --remove-orphans

verify: ## Runs the acceptance criteria of HU 01.1
	$(VERIFY_SH) scripts/verify-ca.sh
