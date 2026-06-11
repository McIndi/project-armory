# Keycloak Extraction Plan — Standalone Keycloak in project-armory

> **ARCHIVED — executed. Kept for history; do not follow as current
> instructions.** Durable rationale lives in [../decisions/](../decisions/).

Status: proposed (evaluation stage — no changes applied)
Scope: extract Keycloak from the bundled BeeAI/Agent Stack Helm chart into a
standalone, self-owned Keycloak deployment in project-armory. Remove the
Agent Stack (`beeai_agentstack_tofu`) deployment from armory.
Goal: armory becomes a small, standard, self-explanatory identity provider.
Agent Stack itself moves to a sister project (project-garrison) and consumes
armory's Keycloak as an external OIDC provider.

> Garrison-side work is **out of scope** for this document. Everything Agent
> Stack must account for when running against an external Keycloak is captured
> separately in [`agentstack-keycloak-reqs-for-garrison.md`](../agentstack-keycloak-reqs-for-garrison.md).

## 1. Why

Today Keycloak (and the PostgreSQL backing it, plus SeaweedFS, the API server,
and the UI) is deployed as one unit by the `beeai_agentstack_tofu` role via the
Agent Stack Helm chart (`oci://ghcr.io/i-am-bee/agentstack/chart`). Two armory
components — the k3s API-server OIDC config and Headlamp — piggyback on the
`agentstack` realm that this chart provisions.

This is non-standard and hard to reason about: armory pulls in an entire
*application* chart purely to obtain an *identity provider*. Any agent (human or
AI) working in the repo must first discover that ~80% of the Agent Stack chart
is incidental to armory's actual need (Keycloak), which is a recurring tax on
every task. Removing the application chart and deploying a standard Keycloak
makes armory's identity story legible at a glance.

### Key fact that forces a standalone chart

Keycloak is **not** a subchart dependency of the Agent Stack chart. Per its
[`Chart.yaml`](https://github.com/i-am-bee/beeai-platform/blob/main/helm/Chart.yaml)
the only dependencies are `common`, `postgresql`, `seaweedfs`, `phoenix-helm`,
and `redis`. Keycloak is rendered by the chart's own `templates/`, gated by
`keycloak.enabled`. There is therefore **no clean way to deploy "only the
Keycloak part"** of that chart. A separate, standard Keycloak chart is required.

## 2. Current state (what exists today)

| Concern | Where | Notes |
|---|---|---|
| Keycloak + Keycloak DB | Agent Stack chart, ns `agentstack` | bundled; image `ghcr.io/i-am-bee/agentstack/keycloak-themed:26.5.4` |
| Realm `agentstack` + clients | chart realm import | clients `agentstack-ui`, `agentstack-server`, audience scopes, seed admin user |
| In-cluster Keycloak fixes | [`beeai_agentstack_tofu/tasks/main.yml:696`](../../ansible/roles/beeai_agentstack_tofu/tasks/main.yml) | `KC_HOSTNAME_STRICT=false` patch + startup-probe bump (~237s cold-JVM start) |
| Audience mapper fix | [`keycloak_oidc_fix.yml`](../../ansible/roles/beeai_agentstack_tofu/tasks/keycloak_oidc_fix.yml) | forces `aud: agentstack-server` (Agent Stack specific) |
| Credential source | OpenBao `secret/beeai/credentials` → VSO → k8s secret `beeai-credentials` | admin pw, pg passwords |
| k3s API-server OIDC | [`k3s/defaults/main.yml:77`](../../ansible/roles/k3s/defaults/main.yml), [`k3s/tasks/oidc.yml`](../../ansible/roles/k3s/tasks/oidc.yml) | issuer `…/realms/agentstack`, client `headlamp`; restarts k3s |
| Headlamp OIDC | [`headlamp/tasks/oidc_client.yml`](../../ansible/roles/headlamp/tasks/oidc_client.yml), [`headlamp/defaults/main.yml:27`](../../ansible/roles/headlamp/defaults/main.yml) | creates `headlamp` client in realm `agentstack`; reads `keycloak-secret` admin pw |
| Readiness | [`readiness_check/tasks/check_beeai.yml`](../../ansible/roles/readiness_check/tasks/check_beeai.yml) | Agent Stack pod/HTTPS checks |

## 3. Target architecture (armory side only)

armory becomes a multi-realm identity provider. One Keycloak, one realm owned by
armory for armory's own infrastructure consumers.

```
project-armory (identity provider)
├─ keycloak role (standard chart)
│   ├─ PostgreSQL for Keycloak (or reuse a shared pg)
│   ├─ credentials via OpenBao + VSO
│   ├─ KC_HOSTNAME_STRICT + startup-probe carry-over
│   ├─ ingress for /realms/...  (armory-tls)
│   └─ realm `armory`
│       ├─ client `headlamp`   (Headlamp dashboard)
│       └─ client for k3s API-server OIDC
├─ k3s OIDC      → issuer …/realms/armory
├─ headlamp      → realm `armory`
└─ readiness     → checks Keycloak (not Agent Stack)
```

The `agentstack` realm and its clients are **not** an armory concern under this
plan — they become garrison's responsibility (see the companion doc). armory
stays Agent-Stack-ignorant.

## 4. Work breakdown (armory)

### 4.1 New `keycloak` role
- Choose a standard chart (see Open Questions §6). Deploy Keycloak + its
  PostgreSQL.
- Lift credential wiring from `beeai_agentstack_tofu`: OpenBao KV → VSO →
  k8s secret for admin password and DB passwords.
- Carry over the proven in-cluster fixes that are Keycloak-generic:
  - `KC_HOSTNAME_STRICT=false` StatefulSet patch
  - startup-probe `failureThreshold` bump for cold-JVM start
  - `/realms/...` Ingress on `armory-tls`
- Provision realm `armory` (prefer a realm-import values block over post-hoc
  REST mutation, for legibility).

### 4.2 Realm `armory` definition
- Realm role(s) needed by armory consumers (e.g. an admin/group role for k3s
  RBAC mapping via the `groups` claim).
- Client `headlamp` (confidential, standard flow; redirect URIs to the Headlamp
  ingress host) — Headlamp role already provisions this via REST and can be
  re-pointed at the new realm.
- Client for k3s API-server OIDC (`oidc-client-id`).
- Seed admin user + role assignment (replaces the chart's `seedAgentstackUsers`).

### 4.3 Repoint k3s OIDC
- `k3s_oidc_issuer_url` → `…/realms/armory` ([`k3s/defaults/main.yml:77`](../../ansible/roles/k3s/defaults/main.yml)).
- Confirm `k3s_oidc_client_id` / claims still valid against the `armory` realm.
- OIDC-CA sync flow ([`k3s/tasks/oidc.yml`](../../ansible/roles/k3s/tasks/oidc.yml))
  is unchanged in shape — only the CA source secret/namespace may move.

### 4.4 Repoint Headlamp
- `headlamp_keycloak_realm` → `armory` ([`headlamp/defaults/main.yml:27`](../../ansible/roles/headlamp/defaults/main.yml)).
- Replace the `beeai_*`-derived defaults Headlamp borrows
  (`beeai_keycloak_service_name`, `beeai_keycloak_service_port`,
  `beeai_tofu_namespace`) with `keycloak`-role-owned vars
  ([`headlamp/defaults/main.yml:29`](../../ansible/roles/headlamp/defaults/main.yml)).
- The REST client-provisioning logic in
  [`oidc_client.yml`](../../ansible/roles/headlamp/tasks/oidc_client.yml) is reusable
  as-is against the new realm.

### 4.5 Readiness + cleanup
- Remove the Agent Stack block from readiness
  ([`check_beeai.yml`](../../ansible/roles/readiness_check/tasks/check_beeai.yml));
  add a Keycloak health/realm check.
- Remove `beeai_agentstack_tofu` from [`site.yml`](../../ansible/playbooks/site.yml)
  and delete the role (work is preserved in git history and migrates to garrison).
- Decide VSO ownership: VSO is currently set up inside `beeai_agentstack_tofu`.
  If Keycloak needs VSO-synced credentials, VSO setup must move into the
  `keycloak` role (or a shared role) rather than vanish with the Agent Stack role.
- Prune `BEEAI_*` env vars and Agent Stack sections from `.env.example` and
  `README.md`.

## 5. Engineering to preserve (do not lose)

The following are hard-won and Keycloak-generic — carry them into the `keycloak`
role rather than discarding with the Agent Stack role:
- `KC_HOSTNAME_STRICT=false` patch (chart hardcodes strict mode; breaks
  in-cluster `http://keycloak:8336` access → NXDOMAIN redirect to public host).
- Startup-probe `failureThreshold` raise (Quarkus augmentation alone ~237s on the
  target host; default probe kills Keycloak before first ready).
- `/realms/...` ingress + TLS via `armory-tls`.

The **audience-mapper fix** ([`keycloak_oidc_fix.yml`](../../ansible/roles/beeai_agentstack_tofu/tasks/keycloak_oidc_fix.yml))
is Agent-Stack-specific (`aud: agentstack-server`) and does **not** belong in
armory's `keycloak` role. It is documented for garrison in the companion doc.

## 6. Open questions / risks (armory)

1. **Chart choice.** Candidates: Bitnami `keycloak`, codecentric `keycloakx`, or
   the upstream Keycloak Operator. Decision criteria: realm-import support,
   external-DB support, maintenance posture, and how cleanly the existing
   hostname/probe patches map. (The Agent Stack `keycloak-themed:26.5.4` image
   carries an Agent Stack login theme — irrelevant to armory's own realm; armory
   should use a stock Keycloak image.)
2. **Realm definition mechanism.** Realm-import (declarative, preferred) vs
   post-hoc REST provisioning (current Headlamp pattern). Realm-import is more
   legible and idempotent.
3. **PostgreSQL topology.** Dedicate a Postgres to Keycloak, or share one. Keep
   it simple and standard.
4. **VSO continuity.** Ensure VSO and the OpenBao credential path survive the
   removal of `beeai_agentstack_tofu` if Keycloak depends on them.
5. **k3s claim/role mapping.** Confirm the `groups`/role claims that k3s RBAC
   expects are produced by the new `armory` realm.

## 7. Out of scope

Everything project-garrison must do to deploy Agent Stack against this Keycloak
(external-OIDC contract, realm/client/audience/role bootstrap, in-cluster issuer
and TLS-trust concerns) lives in
[`agentstack-keycloak-reqs-for-garrison.md`](../agentstack-keycloak-reqs-for-garrison.md).
