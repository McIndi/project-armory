# Project Armory — Network & Port Map

## Overview

Project Armory uses a containerized architecture with services communicating over a shared Podman network. All services use TLS with certificates managed by Vault PKI.

---

## Network Topology Diagram

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'fontSize': '13px'}}}%%
flowchart TB

    %% ═══════════════════════════════════════════════════════════════════
    %% HOST — Fedora 43 VM  (Vagrant + VirtualBox sits below this layer)
    %% ═══════════════════════════════════════════════════════════════════
    subgraph HOST["Fedora 43 VM · rootless Podman"]
        direction TB

        %% ── Loopback port bindings exposed to the host ─────────────────
        subgraph LB["127.0.0.1 — Loopback Port Bindings  (localhost only by default)"]
            direction LR
            b8200["<b>:8200</b><br/>Vault API / UI"]
            b5432["<b>:5432</b><br/>PostgreSQL"]
            b8444["<b>:8444</b><br/>Keycloak HTTPS"]
            b8443["<b>:8443</b><br/>Nginx HTTPS"]
            b8445["<b>:8445</b><br/>Agent API HTTPS"]
        end

        %% ═══════════════════════════════════════════════════════════════
        %% ARMORY-NET — single Podman bridge network
        %% Vault compose creates it; every other service joins as external.
        %% ═══════════════════════════════════════════════════════════════
        subgraph NET["armory-net · Podman bridge  (created by Vault compose — all services join as external)"]
            direction TB

            %% ── Vault (secret & PKI authority) ────────────────────────
            VAULT[["<b>armory-vault</b><br/>────────────────────────────<br/>Image: quay.io/openbao/openbao:2.5.2<br/>:8200  API + UI  HTTPS  ← published<br/>:8201  Raft cluster  ← internal only<br/>TLS: self-signed CA  /vault/tls/ca.crt<br/>Auth mounts: approle · oidc<br/>PKI mounts:  pki_int · pki_ext"]]

            %% ── PostgreSQL stack ───────────────────────────────────────
            subgraph PG_S["PostgreSQL Stack"]
                direction LR
                VA_PG["<b>armory-postgres-vault-agent</b><br/>──────────────────────<br/>Sidecar: OpenBao agent<br/>Auth: AppRole  approle/postgres<br/>Policies: postgres_db · postgres_pki<br/>Writes: postgres.pem"]
                PG[("  <b>armory-postgres</b>  <br/>──────────────────────<br/>postgres:16-alpine<br/>:5432  PostgreSQL + TLS<br/>CN: armory-postgres.armory.internal<br/>CA: pki_int  TTL: 24h")]
            end

            %% ── Keycloak stack ─────────────────────────────────────────
            subgraph KC_S["Keycloak Stack  (OIDC Identity Provider)"]
                direction LR
                VA_KC["<b>armory-vault-agent-keycloak</b><br/>──────────────────────<br/>Sidecar: OpenBao agent<br/>Auth: AppRole  approle/keycloak<br/>Policies: keycloak_db · keycloak_pki<br/>          · kv_reader_keycloak<br/>Writes: keycloak.pem<br/>        + keycloak.env<br/>        + keycloak-admin.env"]
                KC["<b>armory-keycloak</b><br/>──────────────────────<br/>keycloak:24.0<br/>:8443  OIDC + Admin UI  HTTPS<br/>Realm: armory<br/>CN: armory-keycloak<br/>CA: pki_ext  TTL: 720h<br/>DB: armory-postgres:5432 (JDBC+TLS)"]
            end

            %% ── Nginx / Webserver stack ────────────────────────────────
            subgraph WEB_S["Webserver Stack"]
                direction LR
                VA_WEB["<b>armory-vault-agent</b>  (webserver)<br/>──────────────────────<br/>Sidecar: OpenBao agent<br/>Auth: AppRole  approle/nginx<br/>Policies: nginx_pki<br/>Writes: nginx.pem"]
                NGINX["<b>armory-webserver</b><br/>──────────────────────<br/>nginx:alpine<br/>:443  HTTPS reverse proxy<br/>CN: armory-webserver<br/>CA: pki_ext  TTL: 720h"]
            end

            %% ── Agent API stack ────────────────────────────────────────
            subgraph AGENT_S["Agent API Stack"]
                direction LR
                VA_AGENT["<b>vault-agent</b>  (agent)<br/>──────────────────────<br/>Sidecar: OpenBao agent<br/>Auth: AppRole  approle/agent<br/>Policies: agent_pki<br/>Writes: agent.pem"]
                AGENTAPI["<b>agent-api</b><br/>──────────────────────<br/>Python FastAPI (uvicorn)<br/>:8443  HTTPS REST API<br/>CN: armory-agent<br/>CA: pki_ext  TTL: 720h<br/>Auth: Keycloak OIDC Bearer token"]
            end
        end
    end

    %% ════════════════════════════════════════════
    %% A · Host port bindings  (loopback → container)
    %% ════════════════════════════════════════════
    b8200 -->|"127.0.0.1:8200 → :8200  HTTPS"| VAULT
    b5432 -->|"127.0.0.1:5432 → :5432  TCP+TLS"| PG
    b8444 -->|"127.0.0.1:8444 → :8443  HTTPS"| KC
    b8443 -->|"127.0.0.1:8443 → :443   HTTPS"| NGINX
    b8445 -->|"127.0.0.1:8445 → :8443  HTTPS"| AGENTAPI

    %% ════════════════════════════════════════════
    %% B · Vault Agent sidecars → Vault  (AppRole auth)
    %% ════════════════════════════════════════════
    VA_PG    -->|"armory-vault:8200  HTTPS<br/>AppRole auth + pki_int issue"| VAULT
    VA_KC    -->|"armory-vault:8200  HTTPS<br/>AppRole auth + pki_ext issue + KV read"| VAULT
    VA_WEB   -->|"armory-vault:8200  HTTPS<br/>AppRole auth + pki_ext issue"| VAULT
    VA_AGENT -->|"armory-vault:8200  HTTPS<br/>AppRole auth + pki_ext issue"| VAULT

    %% ════════════════════════════════════════════
    %% C · Vault Agent sidecars → Service  (shared-volume cert injection)
    %% ════════════════════════════════════════════
    VA_PG    -. "shared volume<br/>postgres.pem" .-> PG
    VA_KC    -. "shared volume<br/>keycloak.pem + .env files" .-> KC
    VA_WEB   -. "shared volume<br/>nginx.pem" .-> NGINX
    VA_AGENT -. "shared volume<br/>agent.pem" .-> AGENTAPI

    %% ════════════════════════════════════════════
    %% D · Service-to-service  (Podman DNS on armory-net)
    %% ════════════════════════════════════════════
    KC       -->|"armory-postgres:5432<br/>JDBC + TLS  sslmode=require"| PG
    AGENTAPI -->|"armory-keycloak:8443<br/>OIDC token introspection  HTTPS"| KC
    AGENTAPI -->|"armory-postgres:5432<br/>SELECT queries + TLS"| PG
    AGENTAPI -->|"armory-vault:8200<br/>AppRole + Vault API  (runtime)"| VAULT
    VAULT    -->|"armory-keycloak:8443<br/>OIDC discovery + token verify"| KC

    %% ════════════════════════════════════════════
    %% Styles
    %% ════════════════════════════════════════════
    classDef vault   fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px,color:#1b5e20
    classDef svc     fill:#bbdefb,stroke:#1565c0,stroke-width:2px,color:#0d47a1
    classDef agent   fill:#ffe0b2,stroke:#e65100,stroke-width:2px,color:#bf360c
    classDef binding fill:#f3e5f5,stroke:#6a1b9a,stroke-width:1px,color:#4a148c

    class VAULT vault
    class PG,KC,NGINX,AGENTAPI svc
    class VA_PG,VA_KC,VA_WEB,VA_AGENT agent
    class b8200,b5432,b8444,b8443,b8445 binding
```

### Legend

| Color | Meaning |
|-------|---------|
| Green | Vault / secret authority |
| Blue | Application service containers |
| Orange | Vault Agent sidecar containers |
| Purple | Host-side loopback port bindings |

| Arrow style | Meaning |
|-------------|---------|
| Solid `-->` | Active network call (HTTPS / TCP) |
| Dotted `-.->` | Shared-volume write (cert/secret injection, no network) |

**Port notation**: `host_ip:host_port → container_port`

---

## PKI Certificate Hierarchy

```mermaid
%%{init: {'theme': 'base'}}%%
flowchart TB
    subgraph PKI["Vault PKI — Certificate Authority Chain"]
        direction TB

        ROOT["<b>Vault Self-Signed Root CA</b><br/>Generated at bootstrap<br/>/vault/tls/ca.crt  (shared with all containers)"]

        subgraph INT_CA["pki_int  —  Internal Intermediate CA"]
            INT["<b>Armory Internal CA</b><br/>Role: armory-server<br/>CN pattern: armory-*.armory.internal"]
            PG_CERT["armory-postgres.armory.internal<br/>TTL: 24h  (auto-renewed by agent)"]
            INT --> PG_CERT
        end

        subgraph EXT_CA["pki_ext  —  External Intermediate CA"]
            EXT["<b>Armory External CA</b><br/>Role: armory-external<br/>CN pattern: armory-*"]
            KC_CERT["armory-keycloak<br/>TTL: 720h"]
            WEB_CERT["armory-webserver<br/>TTL: 720h"]
            AGENT_CERT["armory-agent<br/>TTL: 720h"]
            EXT --> KC_CERT
            EXT --> WEB_CERT
            EXT --> AGENT_CERT
        end

        ROOT --> INT
        ROOT --> EXT
    end

    classDef ca    fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px,color:#1b5e20
    classDef leaf  fill:#bbdefb,stroke:#1565c0,stroke-width:1px,color:#0d47a1
    class ROOT,INT,EXT ca
    class PG_CERT,KC_CERT,WEB_CERT,AGENT_CERT leaf
```

### Legend

- **Port format**: `host_port:container_port`

---

## Network Architecture

### Primary Network: `armory-net`
- **Type**: Podman bridge network
- **Driver**: bridge
- **Created by**: Vault compose (compose-internal alias `vault-net`; physical name `armory-net`)
- **Joined by**: All other service compose stacks declare it as `external: true` (each uses a local alias: `postgres-net`, `keycloak-net`, `webserver-net`, `agent-net`)
- **Purpose**: Single shared network for all container-to-container communication — Vault, all services, and all Vault Agent sidecars

---

## Services & Containers

### 1. Vault (Secret Management)
**Container Name**: `armory-vault`  
**Image**: `quay.io/openbao/openbao:2.5.2` (or HashiCorp Vault)  
**Network**: `armory-net` (Vault compose creates this bridge; its compose-internal alias is `vault-net`)

#### Ports
| Binding | Protocol | Port | Access | Purpose |
|---------|----------|------|--------|---------|
| localhost | HTTPS | 8200 | Host only | Vault API & UI |
| Container internal | HTTPS | 8200 | Internal (armory-net) | Vault API for other services |
| Container internal | HTTPS | 8201 | Internal (not published) | Raft cluster communication (single-node only) |

**Note:** Port 8201 is used for Raft clustering but is **NOT published** to the host (no inter-node traffic in single-node deployment). See **ADR-007**.

#### Vault API Access Points
- **From Host**: `https://127.0.0.1:8200` (localhost only)
- **From Containers** (via armory-net): `https://armory-vault:8200`
- **TLS CA**: Vault generates its own self-signed CA (`/vault/tls/ca.crt`)

#### Environment Variables (for services)
```
VAULT_ADDR=https://armory-vault:8200
VAULT_CACERT=/vault/tls/ca.crt
BAO_ADDR=https://armory-vault:8200
BAO_CACERT=/vault/tls/ca.crt
```

---

### 2. PostgreSQL (Database)
**Container Name**: `armory-postgres`  
**Image**: `docker.io/postgres:16-alpine`  
**Network**: `armory-net`

#### Ports
| Internal | External | Protocol | Access | Purpose |
|----------|----------|----------|--------|---------|
| Container 5432 | 127.0.0.1:5432 | PostgreSQL | Host only | Database access |
| Container 5432 | armory-postgres:5432 | PostgreSQL | armory-net | Internal database |

#### Access Points
- **From Host**: `127.0.0.1:5432`
- **From Containers** (Keycloak, etc.): `armory-postgres:5432`
- **TLS**: Enabled with certificates from Vault PKI (internal CA)

#### TLS Certificate Details
- **CN**: `armory-postgres.armory.internal`
- **TTL**: 24 hours
- **Managed by**: Vault PKI `pki_int` mount

---

### 3. Keycloak (OIDC Identity Provider)
**Container Name**: `armory-keycloak`  
**Image**: `quay.io/keycloak/keycloak:24.0`  
**Network**: `armory-net`

#### Ports
| Internal | External | Protocol | Access | Purpose |
|----------|----------|----------|--------|---------|
| Container 8443 | `${host_ip}:${keycloak_port}` | HTTPS | Configurable | Keycloak UI & OIDC |

#### Configuration
- **Container listens on**: 8443 (standard HTTPS)
- **Default host_ip**: `127.0.0.1` (localhost only)
- **Default host_port**: 8444 (configurable via `keycloak_port` variable)
- **Actual binding**: `127.0.0.1:8444:8443` (host:container mapping)
- **Database**: PostgreSQL at `armory-postgres:5432`
- **Database**: Uses TLS connection with `ssl=true&sslmode=require`

#### TLS Certificate Details
- **CN**: `armory-keycloak`
- **TTL**: 720 hours (30 days)
- **Managed by**: Vault PKI `pki_ext` mount (external CA)

#### Database Connectivity
```
KC_DB_URL=jdbc:postgresql://armory-postgres:5432/keycloak?ssl=true&sslmode=require
KC_DB_USERNAME=keycloak
```

#### Keycloak Admin Credentials
- **Source**: Vault KV v2 at `kv/data/keycloak/admin`
- **Injected via**: Vault Agent sidecar

---

### 4. Nginx (Webserver / Reverse Proxy)
**Container Name**: `armory-webserver`  
**Image**: `docker.io/nginx:alpine`  
**Network**: `armory-net`

#### Ports
| Internal | External | Protocol | Access | Purpose |
|----------|----------|----------|--------|---------|
| Container 443 | `${host_ip}:${host_port}` | HTTPS | Configurable | HTTPS reverse proxy |

#### Configuration
- **Container listens on**: 443 (standard HTTPS)
- **Default host_ip**: `127.0.0.1` (localhost only)
- **Default host_port**: 8443 (configured for rootless Podman)
- **Actual binding**: `127.0.0.1:8443:443` (host:container mapping)

#### TLS Certificate Details
- **CN**: `armory-webserver`
- **TTL**: 720 hours (30 days)
- **Managed by**: Vault PKI `pki_ext` mount (external CA)

---

---

## Complete Port Reference

This section clarifies all port bindings using standard Podman compose notation: `host_ip:host_port:container_port`

| Service | Container | Port | Host Binding | Notes |
|---------|-----------|------|--------------|-------|
| Vault | armory-vault | 8200 (API) | 127.0.0.1:8200:8200 | Localhost only (ADR-007) |
| Vault | armory-vault | 8201 (Raft) | **NOT published** | Internal only, no inter-node traffic in single-node deployment |
| Keycloak | armory-keycloak | 8443 (HTTPS) | 127.0.0.1:8444:8443 | Default; customize with `host_ip` & `keycloak_port` |
| Nginx | armory-webserver | 443 (HTTPS) | 127.0.0.1:8443:443 | Default; customize with `host_ip` & `host_port` |
| PostgreSQL | armory-postgres | 5432 (TCP) | 127.0.0.1:5432:5432 | Localhost only (ADR-007) |

---

| From | To | Hostname | Port | Protocol | Purpose |
|------|-----|----------|------|----------|---------|
| All Services | Vault | `armory-vault` | 8200 | HTTPS | Secret retrieval, PKI, auth |
| Keycloak | PostgreSQL | `armory-postgres` | 5432 | PostgreSQL + TLS | Database queries |
| Vault Agent (Postgres) | Vault | `armory-vault` | 8200 | HTTPS | Certificate injection |
| Vault Agent (Keycloak) | Vault | `armory-vault` | 8200 | HTTPS | Certificate & secrets injection |
| Vault Agent (Nginx) | Vault | `armory-vault` | 8200 | HTTPS | Certificate injection |

---

## Vault Agent Sidecars

Each service includes a Vault Agent sidecar for certificate and secret injection.

### Vault Agent (Postgres Service)
**Container Name**: `armory-postgres-vault-agent` (or `armory-vault-agent-postgres`)  
**Image**: `quay.io/openbao/openbao:2.5.2`  
**Network**: `armory-net`

- **Config**: `/vault/agent/agent.hcl`
- **AppRole Auth**: Via AppRole credentials
- **Output**: `/vault/certs/postgres.pem` (combined cert + key)

### Vault Agent (Keycloak Service)
**Container Name**: `armory-vault-agent-keycloak`  
**Image**: `quay.io/openbao/openbao:2.5.2`  
**Network**: `armory-net`

- **Config**: `/vault/agent/agent.hcl`
- **AppRole Auth**: Via AppRole credentials
- **Outputs**:
  - `/vault/certs/keycloak.pem` (combined cert + key)
  - `/vault/secrets/keycloak.env` (database credentials)
  - `/vault/secrets/keycloak-admin.env` (admin credentials)

### Vault Agent (Nginx Service)
**Container Name**: `armory-vault-agent` (in webserver compose)  
**Image**: `quay.io/openbao/openbao:2.5.2`  
**Network**: `armory-net`

- **Config**: `/vault/agent/agent.hcl`
- **AppRole Auth**: Via AppRole credentials
- **Output**: `/vault/certs/nginx.pem` (combined cert + key)

---

## TLS/PKI Configuration

### Vault PKI Mounts

| Mount | Purpose | Default | Used By |
|-------|---------|---------|---------|
| `pki_int` | **Internal** intermediate CA | Mount path: `pki_int` | PostgreSQL, internal services |
| `pki_ext` | **External** intermediate CA | Mount path: `pki_ext` | Keycloak, Nginx (client-facing) |
| `approle` | AppRole authentication | Mount path: `approle` | Vault Agents in all services |

### Vault PKI Roles

| Role | Mount | Purpose | CN Pattern |
|------|-------|---------|------------|
| `armory-server` | `pki_int` | Internal service certs | `armory-*.armory.internal` |
| `armory-external` | `pki_ext` | External/public service certs | `armory-*` (any subdomain) |

### Certificate Details

| Service | CA | CN | TTL | Role |
|---------|----|----|-----|------|
| PostgreSQL | Internal | `armory-postgres.armory.internal` | 24h | `armory-server` |
| Keycloak | External | `armory-keycloak` | 720h | `armory-external` |
| Nginx | External | `armory-webserver` | 720h | `armory-external` |

---

### Default Configuration Summary

### Host Bindings (All Localhost by Default)

```
┌─────────────────────────────────────────────────┐
│ External Access (Host Bindings)                 │
├─────────────────────────────────────────────────┤
│ Vault       → 127.0.0.1:8200                    │
│ Keycloak    → 127.0.0.1:8444 (→ container 8443)│
│ Nginx       → 127.0.0.1:8443 (→ container 443) │
│ PostgreSQL  → 127.0.0.1:5432                    │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│ Internal Container Network (armory-net)         │
├─────────────────────────────────────────────────┤
│ armory-vault:8200       (Vault API)             │
│ armory-vault:8201       (Raft - not published)  │
│ armory-postgres:5432    (PostgreSQL)            │
│ armory-keycloak:8443    (Keycloak HTTPS)        │
│ armory-webserver:443    (Nginx HTTPS)           │
└─────────────────────────────────────────────────┘
```

### Base Directory Structure

```
/opt/armory/
├── vault/
│   ├── config/
│   ├── data/          (Raft storage)
│   ├── tls/           (CA cert, server cert/key)
│   └── logs/
├── postgres/
│   ├── data/          (pgdata)
│   ├── certs/         (injected by Vault Agent)
│   └── config/
├── keycloak/
│   ├── certs/         (injected by Vault Agent)
│   ├── secrets/       (env files from Vault)
│   └── config/
└── webserver/
    ├── certs/         (injected by Vault Agent)
    ├── nginx/
    └── config/
```

---

## AppRole Authentication

Each service's Vault Agent authenticates via AppRole:

| Service | Role ID | Secret ID | Policy |
|---------|---------|-----------|--------|
| Postgres Agent | `approle/postgres` | (rotated) | `postgres_db`, `postgres_pki` |
| Keycloak Agent | `approle/keycloak` | (rotated) | `keycloak_db`, `keycloak_pki`, `kv_reader_keycloak` |
| Nginx Agent | `approle/nginx` | (rotated) | `nginx_pki` |

- **Mount**: `approle` (configurable)
- **Storage**: `.hcl` files in each service's `approle` directory
- **Renewal**: Automatic via Vault Agent

---

## Network Access Restrictions (Security)

Per **ADR-007 (No Host Port Publishing)**, the architecture enforces:

- ✅ **Internal container communication**: Via `armory-net` (no port publishing)
- ❌ **No raw port publishing**: Services don't bind ephemeral host ports directly
- ✅ **Controlled external access**: Only explicit `host_ip:host_port` bindings
- ✅ **Localhost default**: All external bindings default to `127.0.0.1` (loopback only)
- ✅ **TLS everywhere**: All inter-container communication uses TLS certificates

### To Enable External Access

Modify the relevant `.tfvars`:
```hcl
# For Keycloak
host_ip       = "0.0.0.0"  # or specific LAN IP
keycloak_port = 8444

# For Nginx
host_ip   = "192.168.1.50"  # or 0.0.0.0
host_port = 8443
```

---

## Environment Variables

### Vault Addresses (Used Everywhere)
- **From Host** (Terraform): `https://127.0.0.1:8200`
- **From Containers**: `https://armory-vault:8200`
- **TLS CA**: `/vault/tls/ca.crt`

### PostgreSQL Connection
- **Hostname**: `armory-postgres` (internal) or `127.0.0.1` (host)
- **Port**: `5432`
- **TLS Mode**: `require` (Keycloak enforces this)
- **JDBC URL** (Keycloak): `jdbc:postgresql://armory-postgres:5432/keycloak?ssl=true&sslmode=require`

### Service Names
- Vault: `armory-vault`
- PostgreSQL: `armory-postgres`
- Keycloak: `armory-keycloak`
- Nginx: `armory-webserver`

---

## Networking Notes

1. **Single shared network**: All containers — including Vault — share one Podman bridge network named `armory-net`. The Vault compose project creates it; every other service compose declares it as `external: true`. Each compose file uses a local alias (`vault-net`, `postgres-net`, etc.) that maps to the same physical `armory-net` bridge.
2. **DNS Resolution**: Podman's embedded DNS resolver gives each container a hostname matching its `container_name`. Containers reach each other by name (e.g. `armory-vault`, `armory-postgres`) without any `/etc/hosts` editing.
3. **TLS Verification**: All services verify Vault's CA cert (`/vault/tls/ca.crt`), which is shared as a read-only bind mount into every container.
4. **Vault Agent health checks**: Each service's compose `depends_on` the sidecar Vault Agent with `condition: service_healthy`. The agent is healthy only after it has written the certificate file to the shared volume, guaranteeing the main service starts with valid TLS material.
5. **Port 443 vs 8443**: Nginx internally listens on 443 (standard HTTPS); the host binding defaults to 8443 because rootless Podman cannot bind ports below 1024 without additional kernel capabilities.
6. **Port 8443 collision**: Both Nginx (host :8443 → container :443) and the Agent API (host :8445 → container :8443) use internal port 8443 in their respective containers, but they are different containers so there is no conflict.
