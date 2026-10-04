# tix-platform — entorno local

Infraestructura de desarrollo en contenedores: PostgreSQL detrás de PgBouncer, Redis,
Kafka en modo KRaft y, en perfiles aparte, el stack de observabilidad y la app.
Ver `docker-compose.yml` y `docs/02.md` (HU 01.1).

## Requisitos

- Docker Desktop (o Docker Engine + Compose v2). Probado con Docker 29.6.2 y Compose v5.3.1.
- Para los atajos: GNU Make. En Windows se instala con `winget install GnuWin32.Make`
  (el que llega es GNU Make 3.81). Sin `make`, todo se puede hacer con `docker compose`
  directo — está en la tabla de abajo.
- Maven 3.9+ y JDK 21 solo para compilar la app (perfil `full`).

### `make` en Windows

El Makefile no define `SHELL`, a propósito. El make de GnuWin32 busca `/bin/sh`, no lo
encuentra en Windows y ejecuta las recipes con `cmd.exe`. Si el Makefile le impusiera un
shell inexistente, todos los targets se romperían.

Las recipes solo usan `docker`, así que andan igual en `cmd.exe` y en `sh`. Los dos
targets que necesitan un shell POSIX lo resuelven solos:

- `make help` está escrito con `$(info)` de make puro, sin `grep` ni `awk`.
- `make verify` busca el `bash` de Git con `$(wildcard C:/Progra~1/Git/bin/bash.exe)`. Va
  con la ruta corta de 8.3 a propósito: entrecomillar un path con espacios en `cmd.exe`
  es frágil. Si no encuentra Git Bash, cae a `sh` (Git Bash, WSL, Linux, macOS).

Si tenés Git instalado en otro lado, se le dice explícito:

```powershell
make verify VERIFY_SH=C:/ruta/al/bash.exe
```

Corriendo `make` desde **Git Bash** también funciona todo, porque ahí Git pone `sh.exe`
en el PATH y make lo usa como shell.

## Arranque

```bash
cp .env.example .env        # Windows PowerShell: Copy-Item .env.example .env
docker compose up -d --wait # o `make up`
sh scripts/verify-ca.sh     # o `make verify` — corre los criterios de aceptación de la HU 01.1
```

`up -d --wait` no termina hasta que los cuatro contenedores están `healthy`. Si algo no
levanta, el comando falla solo: mirá `docker compose logs` (o `make logs`).

| Con `make` | Sin `make` |
|---|---|
| `make up` | `docker compose up -d --wait` |
| `make down` | `docker compose down --remove-orphans` |
| `make reset` | `docker compose down --remove-orphans -v` |
| `make logs` | `docker compose logs -f --tail=100` |
| `make ps` | `docker compose ps` |
| `make psql` | `docker compose exec postgres psql -U app -d tickets` |
| `make psql-pgbouncer` | `docker compose exec pgbouncer psql -h 127.0.0.1 -p 5432 -U app -d tickets` |
| `make verify` | `sh scripts/verify-ca.sh` |
| `make help` | — |
| `make obs` | `docker compose -f docker-compose.yml -f compose/obs.yml --profile obs up -d --wait` |
| `make obs-down` | `docker compose -f docker-compose.yml -f compose/obs.yml --profile obs down --remove-orphans` |
| `make full` | `docker compose -f docker-compose.yml -f compose/full.yml --profile full up -d --wait` |
| `make full-down` | `docker compose -f docker-compose.yml -f compose/full.yml --profile full down --remove-orphans` |
| `make cluster` | `docker compose -f docker-compose.yml -f compose/cluster.yml --profile cluster up -d --wait` |
| `make cluster-down` | `docker compose -f docker-compose.yml -f compose/cluster.yml --profile cluster down --remove-orphans` |

`sh` tampoco está en el PATH de PowerShell. Para correr el script de verificación
desde PowerShell sin `make`:

```powershell
& "C:\Program Files\Git\bin\bash.exe" -lc "cd '$PWD' && sh scripts/verify-ca.sh"
```

> El `-f` se repite en vez de usar `docker compose -f a.yml:b.yml`: con rutas de
> Windows el `:` de la unidad (`C:\...`) choca con el separador y compose busca un
> archivo que no existe.

## Servicios y puertos

| Servicio | Puerto host | Notas |
|---|---|---|
| PostgreSQL 17 | `${POSTGRES_PORT:-5432}` | **Conexión directa.** La usan las migraciones de Flyway |
| PgBouncer 1.26 | `${PGBOUNCER_PORT:-6432}` | Pool de la app, `pool_mode=transaction`. Adentro escucha en 5432 |
| Redis 7 | `${REDIS_PORT:-6379}` | Cache y locks |
| Kafka 4.2 (KRaft) | `${KAFKA_PORT:-9092}` | Sin ZooKeeper. Broker y controller en el mismo nodo |

Dentro de la red de Compose los hosts son nombres de servicio (`postgres:5432`,
`pgbouncer:5432`, `redis:6379`, `kafka:29092`); desde el host son `localhost` con los
puertos de la tabla.

**Por qué las migraciones no van por PgBouncer:** en `pool_mode=transaction` una
transacción se puede fijar a una conexión del servidor distinta a la que la abrió.
El DDL y los *locks* de `pg_*` no sobreviven eso, así que Flyway conecta siempre al
5432 directo. Son dos URLs distintas a propósito, en `.env` y en `compose/full.yml`.

**Kafka tiene dos listeners.** `PLAINTEXT://localhost:9092` para la app que corre
fuera de Docker, e `INTERNAL://kafka:29092` para la que corre dentro (perfil `full`).
Con un solo listener la app dentro de la red no resuelve el broker.

## Perfiles

Por defecto `make up` levanta **solo la infraestructura base**. Los demás perfiles se
agregan con un archivo de compose y un perfil:

```bash
make obs        # + Prometheus, Grafana, Loki, Alloy, OTel Collector
make full       # + la app (perfil `full`, usa la imagen de HU 08.1)
make cluster    # + Redis Cluster de 6 nodos (3 masters + 3 réplicas)
```

Para volver atrás: `make obs-down`, `make full-down`, `make cluster-down`.
`make down` y `make reset` bajan cualquier combinación de perfiles que esté corriendo.

| Servicio | Puerto host |
|---|---|
| Prometheus | `${PROMETHEUS_PORT:-9090}` → http://localhost:9090 |
| Grafana | `${GRAFANA_PORT:-3000}` → http://localhost:3000 (`admin` / `admin`) |
| Loki | `${LOKI_PORT:-3100}` |
| Alloy (UI) | `${ALLOY_PORT:-12345}` |
| OTLP gRPC / HTTP | `${OTEL_GRPC_PORT:-4317}` / `${OTEL_HTTP_PORT:-4318}` |

`make cluster` publica los nodos en 7001-7006 para no chocar con el Redis standalone
del 6379. Ojo: **en modo cluster Redis anuncia IPs de contenedor**, que desde el host
no son alcanzables; para usar el cluster la app tiene que correr dentro de la red de
Compose (`make full`).

## Tiempos

| Escenario | Tiempo |
|---|---|
| `make up` con imágenes ya descargadas | **medido: 13 s** (CA 3; lo vuelve a medir `make verify` en cada corrida) |
| `make up` la primera vez, con descarga | **medido: 94 s** de pared, descarga incluida |
| Volver a levantar con la base ya inicializada | 2 s |

Las imágenes que baja la primera vez, sin comprimir:

| Imagen | Tamaño |
|---|---|
| `apache/kafka:4.2.2` | 675 MB |
| `postgres:17` | 646 MB |
| `redis:7` | 170 MB |
| `edoburu/pgbouncer:v1.26.0-p0` | 29 MB |
| **Total** | **~1,5 GB** (~750 MB comprimidos, que es lo que viaja por la red) |

Kafka pesa la mitad de todo el stack: es el primero que conviene decidir si hace
falta para lo que estás probando.

El número de la primera fila lo mide `make verify` en cada corrida. Para medir la
descarga de imágenes, borrá las imágenes y cronometrá:

```bash
docker rmi postgres:17 redis:7 apache/kafka:4.2.2 edoburu/pgbouncer:v1.26.0-p0
time make up
```

## Datos y volúmenes

Los datos viven en volúmenes con nombre: `pgdata` (PostgreSQL) y `redisdata` (Redis),
más los de los perfiles (`prometheus-data`, `loki-data`, `alloy-data`, `otel-data`,
`grafana-data`, `redis-1-data`…`redis-6-data`).

| Comando | Qué pasa con los datos |
|---|---|
| `make down` | Se conservan. `make up` los vuelve a usar |
| `make reset` | **Se borran.** La base arranca vacía |

## Problemas frecuentes

**`Bind for 0.0.0.0:5432 failed: port is already allocated`**
Hay otro Postgres (o algo) en ese puerto. No toques el compose: cambiá el puerto en
`.env` y relanzá.

```bash
POSTGRES_PORT=55432     # en .env
make reset && make up   # `reset` porque el volumen quedó ligado al postgres viejo
```

**`failed to solve ... POSTGRES_PASSWORD` o el compose no levanta**
Falta `.env` o `POSTGRES_PASSWORD` está vacío. Es una variable obligatoria a
propósito (`${POSTGRES_PASSWORD:?definir en .env}`): si el compose arrancara con la
contraseña vacía, el primer `psql` al que se conecte crearía el rol con clave en
blanco.

**`cannot connect to the Docker daemon`**
Docker Desktop está apagado. Abrilo y esperá a que diga "Engine running".

**La consulta a PgBouncer falla con error de autenticación**
`compose/full.yml` y `.env` usan `AUTH_TYPE=scram-sha-256`, que es lo que espera
`postgres:17` (`password_encryption` por defecto). El `entrypoint` de la imagen escribe
el `userlist` a partir de `DATABASE_URL`, así que la clave tiene que ser la misma en los
dos lados. Para diagnosticar:

```bash
docker compose logs --tail=50 pgbouncer   # muestra el userlist generado y la config
docker compose exec pgbouncer cat /etc/pgbouncer/pgbouncer.ini
docker compose exec -T postgres sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h pgbouncer -p 5432 -U app -d tickets -tAc "select 1"'
```

Si `POSTGRES_PASSWORD` tiene `@ : / ? #`, el parser de `DATABASE_URL` de la imagen los
confunde con separadores de la URL y el `userlist` sale mal. Ahí conviene una clave
alfanumérica en local.

**`make up` se queda esperando**
Kafka es el service que más tarda. `make ps` muestra en qué estado quedó; el timeout de
`--wait` es el de Compose, no el del healthcheck. `make logs` para ver la causa real.

**`postgres is unhealthy` y `pgbouncer` no levanta**
El `healthcheck` de Postgres tiene `start_period: 60s` por una razón concreta: en la
primera ejecución, sobre un volumen nuevo, el entrypoint corre `initdb` + `CREATE DATABASE`
+ reinicio, y eso puede tardar más que `interval × retries` (`5s × 10 = 50s`). Sin
`start_period` esos fallos cuentan desde el segundo cero, el contenedor queda `unhealthy`,
y como `pgbouncer` depende de `service_healthy`, Compose aborta antes de crearlo.
Durante `start_period` los fallos no cuentan. Si tocás ese valor y el síntoma vuelve,
es este el primer lugar donde mirar.

**Cambié el `POSTGRES_PASSWORD` y no entra más**
La clave solo se aplica la primera vez que se inicializa el volumen, mientras que
pgbouncer regenera su `userlist` en cada arranque. Cambiarla sin `make reset` deja los dos
desalineados: pgbouncer acepta la conexión TCP (`pg_isready` da OK, el healthcheck pasa)
pero el login falla. El síntoma es confuso a propósito: en los logs de pgbouncer solo
aparece `login attempt` y nada más, sin motivo. `make verify` ahora imprime el error de
`psql` cuando pasa, que es lo único que dice la causa real.

```bash
make reset && make up
```

Ojo con el origen de la clave, que es la mitad de la trampa: **una variable de entorno
del shell pisa a `.env`**, porque Docker Compose le da prioridad a las variables ya
exportadas. Exportar `POSTGRES_PASSWORD` "para probar algo" y después correr `make up`
mete la clave nueva en postgres y en pgbouncer, pero **no** en el volumen ya inicializado.
siempre verificá con `grep '^POSTGRES_PASSWORD=' .env` qué espera el compose de verdad.

**Un `.env` con `DB_URL` apuntando a `pgbouncer:5432` no resuelve desde el host**
`pgbouncer` es el nombre del servicio dentro de la red de Compose. Desde el host va
`localhost:6432`. Está en `.env.example` con los dos casos commented.

## Criterios de aceptación de la HU 01.1

`make verify` corre los cinco y devuelve exit 1 si alguno falla. Estado al 2026-10-04:
**9 OK, 0 fallas** (Docker 29.6.2, Compose v5.3.1, GNU Make 3.81 de GnuWin32).

| CA | Qué mide | Resultado |
|---|---|---|
| 1 | `up -d --wait` sale con exit 0 y los cuatro contenedores quedan `healthy` | OK (2 s) |
| 2 | Un marcador sobrevive a `down` + `up`, y desaparece con `reset` | OK |
| 3 | El levantamiento con imágenes ya bajadas tarda menos de 120 s | OK (13 s) |
| 4 | `psql` responde en 5432 y una consulta real atraviesa PgBouncer | OK |
| 5 | `.env` está en `.gitignore`, `.env.example` existe y `.env` no está trackeado | OK (3 de 3; el chequeo de tracking se omite hasta que haya `git init`) |

El script es `scripts/verify-ca.sh`. **El CA 4 tiene una segunda mitad —"las migraciones
usan el directo"— que sigue sin verificarse**: no hay Flyway ni `datasource` en
`application.yaml`, así que no hay migración que todavía. Se cierra en HU 03.1; mientras
tanto la separación de URLs queda documentada arriba y en `.env.example`.

## Quality gates (HU 01.3)

Un solo comando corre todo: `./mvnw -B verify`. En orden:

| Gate | Plugin | Qué falla |
|---|---|---|
| Formato | Spotless 2.44.5 (Google Java Format AOSP) | código o `pom.xml` sin formatear |
| Lint | Checkstyle 10.26.1 (`config/checkstyle/checkstyle.xml`) | cualquier violación |
| Tests | JUnit 5 + Testcontainers 2.0.2 | un test rojo |
| Cobertura | JaCoCo 0.8.13 | LINE < 80 % en `domain`/`application` |

Los tests de integración levantan **PostgreSQL, Redis y Kafka reales** en contenedores
efímeros (`postgres:17`, `redis:7`, `apache/kafka:4.2.2`). No hay H2 ni broker embebido:
si el test pasa, la infraestructura funciona de verdad.

### Los gates están probados, no asumidos

Un gate que nunca falla no sirve de nada, así que cada uno se verificó en las dos
direcciones (2026-10-04):

| Gate | Provocación | Resultado esperado | Resultado obtenido |
|---|---|---|---|
| Checkstyle | línea de 129 caracteres | falla | `LineLength: La línea es mayor de 120 caracteres` |
| Spotless | `pom.xml` con una línea mal formada | falla | `The following files had format violations` |
| JaCoCo | clase en `domain` sin tests, umbral 0.99 | falla | `lines covered ratio is 0.00, but expected minimum is 0.99` |
| JaCoCo | misma clase **con** test, umbral 0.99 | pasa | `All coverage checks have been met` |
| JaCoCo | `domain`/`application` vacíos, umbral 0.80 | pasa | `All coverage checks have been met` |
| gitleaks | clave privada RSA en el repo | falla | `leaks found: 1` (exit 1) |
| gitleaks | repo sin secretos | pasa | `no leaks found` (exit 0) |
| Trivy | `spring-boot 4.0.0` | falla | `CVE-2026-40976` CRITICAL + 2 HIGH (exit 1) |
| Trivy | `spring-boot 4.0.6` + Spring Framework 7.0.8 | pasa | 0 CRITICAL/HIGH (exit 0) |

Comprobación manual de los dos últimos, sin salir de la máquina:

```bash
# secretos (el repo limpio tiene que dar 0; con una clave plantada, 1)
docker run --rm -v .:/repo -w /repo ghcr.io/gitleaks/gitleaks:latest \
  detect --source=/repo --config=/repo/.gitleaks.toml --no-git

# CVEs de dependencias
docker run --rm -v .:/repo -v ~/.m2:/root/.m2 -v trivy-cache:/root/.cache/trivy \
  -w /repo aquasec/trivy:latest fs --scanners vuln --severity CRITICAL,HIGH \
  --exit-code 1 --offline-scan .
```

En PowerShell el equivalente es `.\mvnw.cmd -B verify`.

### Cobertura: el umbral es real, pero hoy no mide nada

El filtro es `com/tix/**/domain/**` y `com/tix/**/application/**`. Esos paquetes existen
pero están vacíos: el primer código de negocio llega con HU 02.1 (`POST /register`). Con el
árbol vacío el bundle filtra vacío y el check pasa sin medir.

**En cuanto haya una clase, el gate exige 80 % sin tocar nada.** Eso se comprobó plantando
una clase real sin tests (falló) y con tests (pasó).

Un detalle que costó encontrar: el `<includes>` **dentro de `<rule>`** matchea vacío siempre
—se probó con notación de barras, de puntos y vacío— y deja el gate muerto sin avisar. Por
eso el filtro va en el `<includes>` **del goal**, que sí funciona. Si alguna vez se mueve,
vuelve a comprobar la tabla de arriba.

Para probar que un PR no baja del umbral, sin esperar a tener código de negocio:

```bash
./mvnw -B verify -Djacoco.line.min=0.99    # debe fallar si hay clases sin cubrir
```

### Workflows

| Archivo | Qué corre |
|---|---|
| `.github/workflows/ci.yml` | `build-test` (verify completo), `gitleaks`, `trivy` |
| `.github/workflows/codeql.yml` | CodeQL (SAST) sobre Java, con schedule semanal |
| `.github/dependabot.yml` | actualizaciones de Maven y de GitHub Actions |
| `.gitleaks.toml` | allowlist de gitleaks, extiende la config por defecto |

Disparadores: `pull_request` y `push` sobre `main`, más `workflow_dispatch`. `permissions`
mínimos por job (`contents: read`, y `security-events: write` solo en CodeQL). `concurrency`
cancela el run anterior del mismo PR, que ayuda al p90 de < 10 min.

**Dependabot y el multi-módulo:** Dependabot lee *un* `pom.xml` por entrada. Con solo
`directory: /` los cuatro módulos quedan sin cubrir, así que hay una entrada por pom.

**Trivy necesita el cache de Maven.** Si no, resuelve el árbol de dependencias por red, se
topa con el rate limit de Maven Central y muere con `FATAL 429`: un build rojo que no
tiene nada que ver con una vulnerabilidad. Por eso el job corre
`./mvnw -B -q dependency:go-offline` antes de escanear.

### Pendiente: branch protection (tarea 1, a medias)

No se puede activar sin remoto. Cuando exista, en **Settings → Branches → Add rule** para
`main`:

- Require a pull request before merging, con al menos 1 aprobación.
- Require status checks to pass, marcando: `build-test`, `gitleaks`, `trivy`, `Analyze (java-kotlin)`.
- Require branches to be up to date before merging.
- Do not allow bypassing the above settings.

Sin ese paso, los checks corren pero nada impide mergear un PR rojo: el CA 1 no se
sustenta solo con el workflow.

### Desviaciones y límites conocidos

- **Las actions no están fijadas por SHA.** La referencia de la HU pide fijarlas por SHA
  completo en producción. No se hizo porque un SHA inventado rompe el workflow y uno
  aproximado rompe la seguridad que se quiere ganar. Hoy van por versión mayor
  (`actions/checkout@v4`). Es un pendiente antes de publicar el repo.
- **El p90 de < 10 min no se puede medir todavía.** Sin remoto no hay historial de Actions.
  La primera medición real sale del primer PR.
- **El gate de cobertura hoy pasa sin medir**, porque el árbol está vacío, como se explica
  arriba. No es un defecto del gate, pero tampoco es cobertura: no hay nada que medir hasta
  HU 02.1.
- **`spring-framework.version` está sobreescrito a 7.0.8** sobre el BOM de Spring Boot
  4.0.6, para cerrar el CVE-2026-41850. El override gana sobre el BOM, así que hay que
  revisarlo en cada PR que suba Spring Boot. Está documentado en el `pom.xml`.
- **Tareas 5 a 9 de la HU 01.3 sin empezar:** imagen, SBOM, firma cosign, GitOps con
  ArgoCD y rollback. La 5 depende del Dockerfile, que llega con HU 08.1.

## Estructura

```text
docker-compose.yml        # infra base: postgres, pgbouncer, redis, kafka
compose/
  full.yml                # perfil full: la app
  obs.yml                 # perfil obs: observabilidad
  cluster.yml             # perfil cluster: Redis Cluster de 6 nodos
  prometheus/prometheus.yml
  grafana/provisioning/datasources/datasources.yml
  loki/loki.yml
  alloy/config.alloy
  otel/otel-collector.yml
scripts/verify-ca.sh      # criterios de aceptación de la HU 01.1
.github/
  workflows/ci.yml        # build + tests + cobertura, gitleaks, trivy
  workflows/codeql.yml    # SAST
  dependabot.yml          # Maven y GitHub Actions
.gitleaks.toml            # allowlist de gitleaks
config/checkstyle/
  checkstyle.xml          # reglas de lint
pom.xml                   # reactor: quality gates y versiones
Makefile
.env.example
```