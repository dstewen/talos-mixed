# Media Apps PostgreSQL Dependency Map

## Current Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    postgres18-rw.database                    │
│              (3 instances, amd64, shared cluster)             │
│                                                             │
│  Radarr      Sonarr        Lidarr      Prowlarr             │
│  Radarr-uhd  Sonarr-uhd    Whisparr    Seerr                │
│  Paperless                                                                │
│                                                             │
│  Each has:                                                  │
│  - init-db container (postgres-init)                        │
│  - ExternalSecret with DB creds in 1Password                │
│  - volsync component for config backup                      │
│  - dependsOn: cloudnative-pg-cluster18                     │
└─────────────────────────────────────────────────────────────┘
```

## Per-App Breakdown

### Radarr
- **Database(s):** `radarr_main`, `radarr_log` (2 DBs)
- **DB Host:** `postgres18-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `cloudnative-pg` + `radarr` + `pushover`
- **Files:** `ks.yaml` (dependsOn), `app/externalsecret.yaml` (template vars), `app/helmrelease.yaml` (init-db container)
- **Migration effort:** Medium (2 databases)

### Radarr-uhd
- **Database(s):** `radarr-uhd_main`, `radarr-uhd_log` (2 DBs)
- **DB Host:** `postgres18-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `cloudnative-pg` + `radarr-uhd`
- **Migration effort:** Medium (2 databases)

### Sonarr
- **Database(s):** `sonarr_main`, `sonarr_log` (2 DBs)
- **DB Host:** `postgres18-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `cloudnative-pg` + `sonarr`
- **Migration effort:** Medium (2 databases)

### Sonarr-uhd
- **Database(s):** `sonarr-uhd_main`, `sonarr-uhd_log` (2 DBs)
- **DB Host:** `postgres18-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `cloudnative-pg` + `sonarr-uhd`
- **Migration effort:** Medium (2 databases)

### Lidarr
- **Database(s):** `lidarr_main` (1 DB)
- **DB Host:** `postgres18-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `cloudnative-pg` + `lidarr`
- **Migration effort:** Low (1 database)

### Prowlarr
- **Database(s):** `prowlarr_main` (1 DB)
- **DB Host:** `postgres18-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `cloudnative-pg` + `prowlarr`
- **Migration effort:** Low (1 database)

### Whisparr
- **Database(s):** `whisparr_main` (1 DB)
- **DB Host:** `postgres18-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `cloudnative-pg` + `whisparr`
- **Migration effort:** Low (1 database)

### Seerr
- **Database(s):** `seerr` (1 DB)
- **DB Host:** `postgres18-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `cloudnative-pg` + `seerr`
- **Migration effort:** Low (1 database)

### Paperless
- **Database(s):** `paperless` (1 DB)
- **DB Host:** `postgres18-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `cloudnative-pg` + `paperless`
- **Migration effort:** Low (1 database, already has postgres-init pattern)
- **NOTE:** ALREADY using `components/postgres` via Immich — same pattern applies!

### Immich (already migrated)
- **Database(s):** `immich` (1 DB)
- **DB Host:** `postgres-vector-rw.database.svc.cluster.local`
- **Init Container:** `postgres-init:18.6.0` (init-db)
- **Secret Source:** `immich` + `cloudnative-pg`
- **Already uses:** `components/postgres`, `components/gpu`, `components/dragonfly`

## ExternalSecret Template Pattern (Current)

```yaml
# Example: radarr
template:
  data:
    RADARR__POSTGRES__HOST: &dbHost postgres18-rw.database.svc.cluster.local
    RADARR__POSTGRES__USER: &dbUser "{{ .RADARR_POSTGRES_USER }}"
    RADARR__POSTGRES__PASSWORD: &dbPass "{{ .RADARR_POSTGRES_PASSWORD }}"
    RADARR__POSTGRES__MAINDB: radarr_main
    RADARR__POSTGRES__LOGDB: radarr_log
    INIT_POSTGRES_DBNAME: radarr_main radarr_log
    INIT_POSTGRES_HOST: *dbHost
    INIT_POSTGRES_USER: *dbUser
    INIT_POSTGRES_PASS: *dbPass
    INIT_POSTGRES_SUPER_PASS: "{{ .POSTGRES_SUPER_PASS }}"
dataFrom:
  - extract: { key: cloudnative-pg }   # provides POSTGRES_SUPER_PASS
  - extract: { key: radarr }           # provides RADARR_POSTGRES_USER/PASS
```

## After Migration (components/postgres pattern)

```yaml
# Example: radarr (after)
# No more ExternalSecret for DB — component generates it
# No more hard-coded host — component provides the Service endpoint
# The component's externalsecret.yaml creates per-app creds
# The component's cluster.yaml creates the Cluster with:
#   - name: ${APP}-postgresql   (Service endpoint: ${APP}-postgresql.database.svc)
#   - bootstrap.recovery from barman archive
#   - storage: 5Gi (can be overridden)
```

## Key Observations

1. **All 8 apps use the same init-db container** (`postgres-init:18.6.0`) — component compatible
2. **Radarr and Sonarr families have 2 DBs each** — component only supports 1 DB in `bootstrap.recovery.database`
3. **All apps use `cloudnative-pg` ExternalSecret** for superuser password — this will change to per-app secrets
4. **Paperless is unique** — it already has a custom `pvc.yaml` with volsync claim, separate from component pattern
5. **Immich is the template** — it already uses `components/postgres`, so it's the migration target pattern
