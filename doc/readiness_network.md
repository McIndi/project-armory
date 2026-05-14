# Incident Report: Pod-to-Pod Network Blocked by Firewalld — HTTP 502 on nginx Ingress

**Date:** 2026-05-12  
**Environment:** Armory2 — BeeAI Agent Stack on Fedora 44 VM, single-node k3s  
**Outcome:** Fully resolved. Readiness check went from 2 critical failures to 0 failures (warnings only).

---

## Table of Contents

1. [TL;DR — For AI Agents and Quick Reference](#tldr)
2. [Environment Context](#environment-context)
3. [Observed Symptoms](#observed-symptoms)
4. [Full Investigation Chronicle](#full-investigation-chronicle)
5. [Root Cause — Deep Technical Explanation](#root-cause)
6. [Why Some Traffic Worked and Some Did Not](#why-asymmetric)
7. [The Fix — Applied Changes](#the-fix)
8. [Code Changes Made to the Playbook](#code-changes)
9. [Verification](#verification)
10. [Background Concepts for Non-Technical Readers](#background-concepts)
11. [Recurrence and Prevention](#recurrence-and-prevention)

---

## 1. TL;DR — For AI Agents and Quick Reference <a name="tldr"></a>

**What broke:** The nginx ingress controller could not connect to backend pods (specifically `agentstack-ui`), returning HTTP 502 Bad Gateway to all requests through the ingress.

**Why:** Linux's `firewalld` (using nftables) has a default `reject` rule at the end of its `filter_FORWARD` chain. Pod-to-pod traffic that passes through the kernel's FORWARD hook (which happens because `net.bridge.bridge-nf-call-iptables=1` is set) was hitting this reject rule because no explicit allow rule covered it. The kube-router iptables ACCEPT that ran earlier (at nftables priority 0) does NOT prevent firewalld (at priority 10) from also running and rejecting the packet.

**Broken config:** Ansible playbook was adding pod/service CIDRs to firewalld's `public` zone (zone target: `default`). The public zone's FORWARD policy only allows traffic out through physical NICs (`enp0s3`, `enp0s8`), not through virtual bridge ports. Pod-to-pod traffic was not covered.

**Fix:** Move both cluster CIDRs (`10.42.0.0/16` pod network, `10.43.0.0/16` service network) from the `public` zone to the `trusted` zone (zone target: `ACCEPT`). The trusted zone generates nftables rules of the form `ip saddr 10.42.0.0/16 → jump filter_FWD_trusted → accept`, which run before the final reject and allow all traffic sourced from pod IPs to forward freely.

**Files changed:**
- `ansible/roles/k3s/defaults/main.yml` — added `k3s_firewall_cluster_cidrs_zone: trusted`
- `ansible/roles/k3s/tasks/firewall.yml` — CIDR tasks now use `k3s_firewall_cluster_cidrs_zone` instead of `k3s_firewall_zone`
- `ansible/roles/readiness_check/tasks/check_helm.yml` — Helm CLI absence changed from `fail` to `warn`

**Key facts for reproduction:**
- The error was `connect() failed (113: Host is unreachable)` in nginx logs — EHOSTUNREACH, not ECONNREFUSED.
- The pod was healthy and listening on its port. The problem was entirely at the Linux firewall/networking layer.
- The host machine could reach the pod IP fine (via the OUTPUT hook, not FORWARD), which masked the issue from simple tests.
- ClusterIP-based pod-to-pod traffic worked (DNAT'd connections have `ct status dnat` and are explicitly accepted by firewalld), but direct pod-IP-to-pod-IP traffic (used by nginx ingress) did not.

---

## 2. Environment Context <a name="environment-context"></a>

### What Armory2 Is

Armory2 is an Ansible project that automates deployment of the BeeAI Agent Stack on a Fedora Linux virtual machine using k3s (a lightweight Kubernetes distribution). It provisions the complete stack:

- **k3s** — Kubernetes cluster (single node, no high availability)
- **OpenBao** — secrets management (open-source HashiCorp Vault fork)
- **nginx ingress** — HTTP/HTTPS reverse proxy with TLS termination
- **cert-manager** — automatic TLS certificate management
- **BeeAI Agent Stack** — the application being served, comprising:
  - `agentstack-server` — API backend (port 8333)
  - `agentstack-ui` — Next.js frontend (port 8334)
  - `keycloak` — identity/authentication provider (port 8336)
  - `postgresql` — relational database (port 5432)
  - `seaweedfs` — object storage
  - `otel-collector` — telemetry collection
- **Vault Secrets Operator (VSO)** — syncs secrets from OpenBao to Kubernetes

All Helm chart installations are managed via **OpenTofu** (the open-source Terraform fork), not the Helm CLI directly.

### Networking Overview

```
Internet / Host Machine
        |
   enp0s3 / enp0s8  (physical NICs)
        |
   firewalld (nftables, manages host packet filtering)
        |
   k3s / kube-proxy / kube-router (Kubernetes network rules)
        |
   cni0 (Linux bridge — acts as a software Ethernet switch for pods)
        |
   veth pairs (virtual Ethernet cables, one per pod)
        |
   Pod eth0 interfaces (inside each pod's isolated network namespace)
```

All pods share the `10.42.0.0/16` address space (pod CIDR). Kubernetes services (ClusterIPs) use `10.43.0.0/16`. The cni0 bridge is at `10.42.0.1` and acts as the gateway for all pod traffic.

### Key Kubernetes Networking Behavior Relevant to This Incident

- **Bridge netfilter** (`net.bridge.bridge-nf-call-iptables=1`): When enabled, traffic traversing the cni0 bridge (pod-to-pod traffic) is also processed by the Linux kernel's netfilter FORWARD hook. This is required for Kubernetes network policies to work, but it also means that firewall rules intended for routed traffic accidentally apply to bridged pod traffic.
- **kube-router**: This stack uses kube-router for Kubernetes network policy enforcement. It installs iptables chains (`KUBE-ROUTER-FORWARD`, `KUBE-POD-FW-*`, `KUBE-NWPLCY-*`) that audit and mark traffic as allowed or denied.
- **nginx ingress backend connections**: nginx ingress communicates with backend pods using their **direct pod IP addresses** (not ClusterIPs). This means these connections are NOT subject to Kubernetes DNAT/NAT translation.

---

## 3. Observed Symptoms <a name="observed-symptoms"></a>

### The Trigger

The full deployment playbook (`ansible-playbook playbooks/site.yml`) was run with debug flags:

```bash
ansible-playbook playbooks/site.yml \
  --extra-vars armory_build_debug=true \
  --extra-vars armory_log_nolog=true \
  -vvv
```

### The Failure

The final `readiness_check` role failed. The readiness report showed:

```
Total Checks: 23 | Passed: 19 | Warned: 2 | Failed: 2

STATUS: ❌ FAILED (2 critical issues found)

BEEAI AGENT STACK
-----------------
  • HTTPS connectivity to https://armory.local
    Status: FAIL
    Detail: HTTP 502 via nodeport fallback
    Error: Status code was -1 and not [200, 301, 302, 401, 403, 502]:
           Request failed: <urlopen error [Errno -3] Temporary failure in name resolution>
           | nodeport fallback HTTP 502

HELM
----
  • Helm CLI available
    Status: FAIL
```

- The DNS failure (`-3`) for `armory.local` is expected — the VM doesn't have an `/etc/hosts` entry for this hostname — so the check falls back to a NodePort connection.
- The NodePort fallback also returned 502, indicating nginx ingress itself was returning "Bad Gateway" for all requests.
- The Helm CLI was not installed (the stack uses OpenTofu to deploy Helm charts, not the CLI directly).

All other checks passed: pods were running, services had endpoints, OpenBao was unsealed, VSO was configured, nginx was running, TLS secrets existed.

---

## 4. Full Investigation Chronicle <a name="full-investigation-chronicle"></a>

Every command run during the investigation, what it revealed, and why the next step was taken.

### Step 1 — Confirm Readiness Check Details

Searched the Ansible log (`log/ansible.log`) for the specific task that failed and for the full readiness report.

**Found:** The readiness report was embedded in the log. The HTTPS connectivity check showed HTTP 502. All other BeeAI checks (namespace, pods, service endpoints, credentials secret) passed. The nodeport fallback confirmed nginx was reachable but returning 502.

### Step 2 — Check Pod Status

```bash
sudo k3s kubectl get pods -n agentstack -o wide
sudo k3s kubectl get pods -n ingress-nginx -o wide
```

**Found:**
- All 7 agentstack pods were Running (1/1 Ready)
- Notably, `agentstack-ui` had been running for **10 hours** — longer than other pods (agentstack-server was 3h44m, keycloak was 28m)
- The nginx ingress controller pod was Running

This ruled out crashed pods as the cause.

### Step 3 — Check nginx Ingress Controller Logs

```bash
sudo k3s kubectl logs -n ingress-nginx ingress-nginx-controller-6c7cd85885-j824q --tail=50
```

**Found** — The critical error:

```
2026/05/12 23:11:32 [error] 565#565: *948372 connect() failed (113: Host is unreachable)
while connecting to upstream, client: 10.42.0.1, server: armory.local,
request: "GET / HTTP/1.1", upstream: "http://10.42.0.18:8334/", host: "armory.local"
```

Error code 113 is `EHOSTUNREACH` — "Host is unreachable." This is a network-level failure, not an application-level failure. nginx was trying to connect to `10.42.0.18:8334` (the `agentstack-ui` pod's pod IP) and the operating system reported the host was completely unreachable.

**Significance:** `EHOSTUNREACH` means the packet couldn't even leave the source — no route or no layer-2 reachability. This is different from `ECONNREFUSED` (which means the port isn't open) or a TCP timeout (which means the packet was dropped silently). This strongly suggested either an ARP failure or a firewall rejection that returned an ICMP unreachable message.

### Step 4 — Verify the Endpoint and Service Configuration

```bash
sudo k3s kubectl get endpoints -n agentstack agentstack-ui-svc -o yaml
sudo k3s kubectl get svc -n agentstack -o wide
```

**Found:** The endpoint was correctly configured — `10.42.0.18:8334` pointing to pod `agentstack-ui-86dc9bc984-jb47b`. The service definition was valid.

This confirmed nginx was using the correct pod IP.

### Step 5 — Test the Pod Directly from the Host

```bash
curl -sv http://10.42.0.18:8334/ 2>&1 | head -30
```

**Found:** The host could reach `10.42.0.18:8334` and received an HTTP 307 redirect:

```
< HTTP/1.1 307 Temporary Redirect
< location: https://armory.local/signin?callbackUrl=https%3A%2F%2Farmory.local%2F
```

**Significance:** The pod was healthy and responding. But the host could reach it while nginx could not. This asymmetry — host works, pod doesn't — is a crucial diagnostic clue (explained fully in [Section 7](#why-asymmetric)).

### Step 6 — Test Pod-to-Pod Connectivity

```bash
# From nginx ingress pod
sudo k3s kubectl exec -n ingress-nginx ingress-nginx-controller-... -- \
  wget -q -O- --timeout=3 http://10.42.0.18:8334/
# Result: wget: can't connect to remote host (10.42.0.18): Host is unreachable

# From agentstack-server pod (a different pod in the same namespace)
sudo k3s kubectl exec -n agentstack agentstack-server-... -- \
  wget -q -O- http://10.42.0.18:8334/
# Result: wget: can't connect to remote host (10.42.0.18): Host is unreachable
```

**Found:** BOTH pods could not reach `10.42.0.18`. This ruled out any issue specific to the nginx ingress pod. The problem affected all pod-to-pod direct connections to `agentstack-ui`.

### Step 7 — Verify the Pod's Network Stack

```bash
# Check what the pod is listening on
sudo k3s kubectl exec -n agentstack agentstack-ui-86dc9bc984-jb47b -- ss -tlnp
```

**Found:**
```
tcp  LISTEN  0  0.0.0.0:8334  0.0.0.0:*  LISTEN  1/next-server (v16.)
```

The pod WAS listening on port 8334 on all interfaces. The application was healthy.

### Step 8 — Verify the Pod's veth Interface

```bash
# From inside the pod
sudo k3s kubectl exec -n agentstack agentstack-ui-86dc9bc984-jb47b -- ip addr show eth0
# Output: eth0@if22 with IP 10.42.0.18/24, MAC 82:de:6f:fb:d2:71

# Find which host veth corresponds to interface index 22
sudo ip link show veth685ecc2e
# Output: 22: veth685ecc2e@if2 ... master cni0 state UP
```

**Found:** The veth pair was correctly connected:
- Pod side: `eth0` (interface index 2 in pod namespace)
- Host side: `veth685ecc2e` (interface index 22 in host namespace)
- The host veth was **UP**, **LOWER_UP**, and its master was **cni0** (connected to the bridge)
- Bridge state was **forwarding** (not blocked)

The physical network plumbing was intact.

### Step 9 — Test ARP Resolution

```bash
# Flush ARP cache and try a pod connection, then check ARP table
sudo ip neigh flush dev cni0
sudo k3s kubectl exec -n ingress-nginx ... -- wget --timeout=3 http://10.42.0.18:8334/ &
sudo ip neigh show dev cni0 | grep 10.42.0.18
# Result: (nothing — no ARP entry appeared)

# Then test from the host
curl -s -o /dev/null http://10.42.0.18:8334/
sudo ip neigh show dev cni0 | grep 10.42.0.18
# Result: 10.42.0.18 lladdr 82:de:6f:fb:d2:71 REACHABLE
```

**Found:** When a pod tried to connect to `10.42.0.18`, no ARP entry appeared. When the host tried, the ARP entry appeared as REACHABLE. The pod's ARP requests were not being answered (or not being sent), but the host's ARP requests were.

This showed the problem was at or below the ARP layer.

### Step 10 — Test ICMP from Inside the Pod's Network Namespace

```bash
# Get the pod's PID on the host
CID=$(sudo crictl ps --name "agentstack-ui" | grep -v "^CONTAINER" | head -1 | awk '{print $1}')
PID=$(sudo crictl inspect $CID | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['pid'])")
# PID: 57326

# Ping nginx ingress pod from agentstack-ui's network namespace
sudo nsenter -t 57326 -n -- ping -c 3 -W 2 10.42.0.12
```

**Found — critical diagnostic:**
```
From 10.42.0.1 icmp_seq=1 Packet filtered
From 10.42.0.1 icmp_seq=2 Packet filtered
From 10.42.0.1 icmp_seq=3 Packet filtered
--- 10.42.0.12 ping statistics ---
3 packets transmitted, 0 received, +3 errors, 100% packet loss
```

"Packet filtered" means the packet WAS sent out but `10.42.0.1` (the cni0 bridge / host gateway) returned an ICMP "Communication Administratively Prohibited" message (ICMP type 3, code 13). This is sent by `firewall-cmd --reject-with icmpx admin-prohibited` in nftables.

**Significance:** The traffic was reaching the host/bridge and being actively rejected by a firewall rule, not silently dropped. This pointed directly to a firewalld/nftables rule.

### Step 11 — Check iptables FORWARD Chain

```bash
sudo iptables -L FORWARD -n -v
```

**Found:**
```
Chain FORWARD (policy ACCEPT)
1  KUBE-ROUTER-FORWARD  all -- * *  0.0.0.0/0  0.0.0.0/0  /* kube-router netpol */
2  KUBE-PROXY-FIREWALL  all -- * *  0.0.0.0/0  0.0.0.0/0  ctstate NEW
3  KUBE-FORWARD         all -- * *  0.0.0.0/0  0.0.0.0/0
4  KUBE-SERVICES        all -- * *  0.0.0.0/0  0.0.0.0/0  ctstate NEW
5  KUBE-EXTERNAL-SERVICES all -- * *  0.0.0.0/0  0.0.0.0/0  ctstate NEW
6  ACCEPT               all -- * *  0.0.0.0/0  0.0.0.0/0  mark match 0x20000/0x20000
7  FLANNEL-FWD          all -- * *  0.0.0.0/0  0.0.0.0/0
```

The chain policy is ACCEPT and rule 6 explicitly ACCEPTs traffic marked by kube-router (`0x20000`). No explicit DROP or REJECT in the chain. The kube-router FORWARD chain accepts pod traffic.

**Yet traffic is still being rejected.** This means something OUTSIDE these iptables chains is rejecting traffic.

### Step 12 — Examine kube-router Pod Firewall Chain

```bash
sudo iptables -L KUBE-POD-FW-DYB4JQDN2KBBM34K -n -v  # chain for agentstack-ui pod
```

**Found:** The chain has a REJECT rule but it only fires for traffic NOT marked with `0x10000`. The `KUBE-NWPLCY-DEFAULT` chain marks ALL traffic with `0x10000` (there are no network policies restricting agentstack-ui). So no traffic is being rejected by this chain.

### Step 13 — Check nftables Firewalld Rules

```bash
sudo nft list ruleset 2>&1 | grep -A10 "filter_FORWARD {"
```

**Found — the smoking gun:**

```
chain filter_FORWARD {
    type filter hook forward priority filter + 10; policy accept;
    ct state { established, related } accept
    ct status dnat accept
    iifname "lo" accept
    ct state invalid drop
    jump filter_FORWARD_POLICIES
    reject with icmpx admin-prohibited    ← THIS IS THE PROBLEM
}
```

The firewalld nftables `filter_FORWARD` chain has a **terminal `reject` statement** as its last line. If a packet reaches this line (i.e., is not accepted by any of the preceding rules), it is rejected with an ICMP "admin prohibited" message.

### Step 14 — Examine filter_FORWARD_POLICIES

```bash
sudo nft list chain inet firewalld filter_FORWARD_POLICIES
```

**Found:**
```
chain filter_FORWARD_POLICIES {
    iifname "enp0s3" oifname "enp0s3" jump filter_FWD_public
    iifname "enp0s3" oifname "enp0s3" reject with icmpx admin-prohibited
    iifname "enp0s3" oifname "enp0s8" jump filter_FWD_public
    ... (many rules, all involving enp0s3 and enp0s8 only)
    jump filter_FWD_public      ← catch-all: send to public zone handler
    reject with icmpx admin-prohibited
}
```

And the public zone forward handler:
```
chain filter_FWD_public_allow {
    oifname "enp0s8" accept
    oifname "enp0s3" accept   ← only accepts traffic going OUT physical NICs
}
```

**Finding:** Every rule in `filter_FORWARD_POLICIES` references `enp0s3` or `enp0s8` (the physical Ethernet NICs). Pod-to-pod traffic goes through veth interfaces attached to the `cni0` bridge, not through physical NICs. So pod traffic falls through to the catch-all `jump filter_FWD_public`, which then falls through `filter_FWD_public_allow` (no match — wrong oifname), and eventually returns to the final `reject with icmpx admin-prohibited`.

### Step 15 — Check Firewalld Zone Configuration

```bash
sudo firewall-cmd --list-all --zone=public
```

**Found:**
```
public (default, active)
  target: default
  interfaces: enp0s3 enp0s8
  sources:
  ...
```

The `sources:` field was **empty**. The Ansible playbook was supposed to add the pod CIDR (`10.42.0.0/16`) as a source to restrict these zones, but it wasn't present in the runtime configuration.

```bash
sudo firewall-cmd --info-zone=public --permanent | grep sources
# sources: 10.42.0.0/16 10.43.0.0/16
```

The CIDRs were in the **permanent** configuration but had not been loaded into the **runtime** configuration. However — crucially — even if they had been loaded into the `public` zone, the `public` zone's FORWARD handler (`filter_FWD_public_allow`) only accepts traffic going out through `enp0s3` or `enp0s8`. Pod traffic would still have been rejected.

**The zone was wrong.** Pod/service CIDRs must be in the `trusted` zone (which has `target: ACCEPT`), not the `public` zone (which has `target: default` and restricts FORWARD traffic to physical NIC paths).

---

## 5. Root Cause — Deep Technical Explanation <a name="root-cause"></a>

### The Two-Layer Firewall Problem

Modern Linux systems running Kubernetes with firewalld have **two independent firewall layers** that both process the same packet:

**Layer 1: iptables (via nftables compatibility)** — at netfilter hook priority 0  
Kubernetes components (kube-router, kube-proxy) install rules here. For pod traffic, kube-router evaluates network policies and marks packets with `0x20000` if allowed, then rule 6 in the FORWARD chain ACCEPTs them.

**Layer 2: firewalld (nftables)** — at netfilter hook priority 10  
The system's host firewall. It runs AFTER iptables. When iptables at priority 0 returns `NF_ACCEPT`, the packet is NOT done — it continues to all registered hooks at higher priority numbers. firewalld at priority 10 runs next and applies its own FORWARD policy.

This is a fundamental property of Linux netfilter: **multiple independent tables can all register the same hook, and all of them run in priority order regardless of what earlier tables decided.** An ACCEPT in one table does not short-circuit processing in other tables.

### Why Bridge Traffic Goes Through the FORWARD Hook

Normally, traffic between two devices on the same Ethernet segment (same bridge) is handled entirely at Layer 2 (switching) and does not go through Layer 3 routing or the FORWARD hook.

However, when `net.bridge.bridge-nf-call-iptables=1` is set (which k3s sets, and which is required for Kubernetes network policies to function), the kernel's bridge code calls the netfilter FORWARD hook for every bridged frame. This makes the kernel treat bridged pod-to-pod traffic as if it were routed traffic for the purpose of firewall processing.

So when nginx at `10.42.0.12` sends a packet to `agentstack-ui` at `10.42.0.18`:
1. Both are on the `cni0` bridge
2. Bridge code handles L2 forwarding AND calls the FORWARD hook
3. iptables (kube-router) at priority 0 marks the packet as allowed
4. firewalld at priority 10 evaluates the packet against its FORWARD chain
5. firewalld's `filter_FORWARD_POLICIES` has no rule for veth-sourced traffic
6. Packet falls through to the terminal `reject with icmpx admin-prohibited`
7. nginx receives an ICMP "admin prohibited" message, which maps to `EHOSTUNREACH`
8. nginx returns HTTP 502 to the client

### Why the Public Zone Doesn't Help

firewalld zones provide a way to group traffic and apply different policies. The Ansible playbook was intended to add `10.42.0.0/16` as a source to the `public` zone, which would cause firewalld to generate rules like:

```
ip saddr 10.42.0.0/16 jump filter_FWD_public
```

But `filter_FWD_public_allow` only ACCEPTs traffic where `oifname` is `enp0s3` or `enp0s8`. Pod-to-pod traffic has a veth interface as its outgoing interface (or the cni0 bridge), not a physical NIC. So even with the CIDRs correctly loaded in the `public` zone, the traffic would still fall through to the REJECT.

### Why the Trusted Zone Fixes It

The `trusted` zone has `target: ACCEPT`. When `10.42.0.0/16` is added as a source to the `trusted` zone, firewalld generates:

```nftables
ip saddr 10.42.0.0/16 jump filter_FWD_trusted
ip saddr 10.42.0.0/16 accept
```

The `filter_FWD_trusted` chain immediately returns ACCEPT for all traffic. Crucially, this rule runs **before** the final `reject` at the end of `filter_FORWARD_POLICIES`. Once the packet is accepted here, it does not reach the reject statement.

After the fix, the nftables chain for pod traffic looks like:
```
filter_FORWARD:
  ct state established/related → accept (return traffic)
  ct status dnat → accept (ClusterIP traffic)
  jump filter_FORWARD_POLICIES:
    ip saddr 10.42.0.0/16 → jump filter_FWD_trusted → ACCEPT ← hit here for pod traffic
    ... (reject never reached)
```

---

## 6. Why Some Traffic Worked and Some Did Not <a name="why-asymmetric"></a>

This section explains the seemingly contradictory observation that some connectivity worked while other connectivity failed.

### Host → Pod (WORKED)

When the host machine (`10.42.0.1`, the cni0 interface) sent a request to a pod (`10.42.0.18`), it used the **OUTPUT hook**, not the FORWARD hook. The OUTPUT hook handles traffic originating from the local machine. firewalld's `filter_FORWARD` chain is only called for the FORWARD hook. So host-originated traffic bypassed the problematic firewall rule entirely.

This is why `curl http://10.42.0.18:8334/` from the host worked fine.

### Pod → Pod via ClusterIP (WORKED)

When pod A connects to another pod B using the **Kubernetes service ClusterIP** (e.g., `10.43.133.49` for PostgreSQL), kube-proxy (or the k3s equivalent) applies **DNAT** (Destination Network Address Translation) to rewrite the destination from the ClusterIP to the actual pod IP. After DNAT, the connection tracking entry has `ct status = dnat`. firewalld's `filter_FORWARD` chain has the rule:

```
ct status dnat accept
```

This explicitly allows all DNAT'd traffic. So ClusterIP-based pod-to-pod communication was working fine.

### Pod → Pod via Direct Pod IP (BROKEN)

nginx ingress connects to backend pods using their **direct pod IP addresses** (not ClusterIPs). nginx reads pod IPs from the Kubernetes Endpoints API. This direct connection is NOT DNAT'd, so `ct status dnat` does not apply. The connection is also new (not `established` or `related`). It falls through to the reject.

### Pod → External (WORKED for established connections)

Once a connection is established (e.g., a pod successfully connects somewhere), return traffic has `ct state related,established` and is accepted immediately. So connections that DID get through (e.g., via ClusterIP with DNAT) had their return traffic flow freely.

### Helm CLI (SEPARATE ISSUE)

The Helm CLI binary was not installed on the VM. This is by design — the stack uses OpenTofu's built-in Helm provider, which downloads and manages Helm charts independently without requiring the `helm` CLI. The readiness check was classifying the absence of the Helm CLI as a `fail` (critical), when it should be a `warn` (informational).

---

## 7. The Fix — Applied Changes <a name="the-fix"></a>

### 7.1 — Immediate Runtime Fix (Applied Manually)

```bash
# Remove CIDRs from the public zone (wrong zone, doesn't help for FORWARD)
sudo firewall-cmd --zone=public --remove-source=10.42.0.0/16 --permanent
sudo firewall-cmd --zone=public --remove-source=10.43.0.0/16 --permanent

# Add CIDRs to the trusted zone (correct — target ACCEPT means FORWARD is allowed)
sudo firewall-cmd --zone=trusted --add-source=10.42.0.0/16 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.43.0.0/16 --permanent

# Reload to apply permanent config to runtime
sudo firewall-cmd --reload
```

After reload, verified the nftables chain contained:
```
ip saddr 10.42.0.0/16 ip daddr 10.42.0.0/16 jump filter_FWD_trusted
ip saddr 10.42.0.0/16 ip daddr 10.42.0.0/16 accept
...
ip saddr 10.42.0.0/16 jump filter_FWD_trusted
ip saddr 10.42.0.0/16 accept
```

### 7.2 — Verification of Network Fix

```bash
# From nginx ingress pod — now succeeds (gets 307 redirect)
sudo k3s kubectl exec -n ingress-nginx ingress-nginx-controller-... -- \
  wget -q -O- --timeout=5 http://10.42.0.18:8334/
# Result: wget: bad address 'armory.local'  (this is correct — it connected and got a 307 redirect to armory.local)

# Via NodePort
curl -k -s -o /dev/null -w "%{http_code}" \
  -H "Host: armory.local" https://127.0.0.1:30443/
# Result: 307  (correct — the redirect to /signin)
```

### 7.3 — Playbook Changes to Prevent Recurrence

Three files were modified.

---

## 8. Code Changes Made to the Playbook <a name="code-changes"></a>

### File 1: `ansible/roles/k3s/defaults/main.yml`

**Added new variable:**

```yaml
# Firewalld zone for cluster CIDR source allowances.
# Must be 'trusted' (target: ACCEPT) so firewalld's filter_FORWARD chain
# accepts pod-to-pod traffic; the public zone only forwards through physical NICs.
k3s_firewall_cluster_cidrs_zone: trusted
```

**Why:** The original code used `k3s_firewall_zone` (default: `public`) for the CIDR source rules. Separating the variable makes the intent explicit and allows operators to change the port-opening zone independently from the CIDR-trust zone. The comment explains the rationale (public zone only allows FORWARD through physical NICs).

### File 2: `ansible/roles/k3s/tasks/firewall.yml`

**Changed both CIDR tasks from `zone: "{{ k3s_firewall_zone }}"` to `zone: "{{ k3s_firewall_cluster_cidrs_zone }}"`:**

Before:
```yaml
- name: Allow k3s pod network CIDR in firewalld
  ansible.posix.firewalld:
    source: "{{ k3s_pod_cidr }}"
    zone: "{{ k3s_firewall_zone }}"   # ← was 'public'
    permanent: true
    state: enabled

- name: Allow k3s service CIDR in firewalld
  ansible.posix.firewalld:
    source: "{{ k3s_service_cidr }}"
    zone: "{{ k3s_firewall_zone }}"   # ← was 'public'
    permanent: true
    state: enabled
```

After:
```yaml
- name: Allow k3s pod network CIDR in firewalld
  ansible.posix.firewalld:
    source: "{{ k3s_pod_cidr }}"
    zone: "{{ k3s_firewall_cluster_cidrs_zone }}"   # ← now 'trusted'
    permanent: true
    state: enabled

- name: Allow k3s service CIDR in firewalld
  ansible.posix.firewalld:
    source: "{{ k3s_service_cidr }}"
    zone: "{{ k3s_firewall_cluster_cidrs_zone }}"   # ← now 'trusted'
    permanent: true
    state: enabled
```

The debug message tasks were also updated to display the correct variable.

### File 3: `ansible/roles/readiness_check/tasks/check_helm.yml`

**Changed Helm CLI absence from `fail` to `warn`:**

Before:
```yaml
'status': 'pass' if _rc_helm_version.rc == 0 else 'fail',
'detail': _rc_helm_version.stdout | default('not found'),
```

After:
```yaml
'status': 'pass' if _rc_helm_version.rc == 0 else 'warn',
'detail': _rc_helm_version.stdout | default('not found (OpenTofu manages Helm charts directly)'),
```

**Why:** The stack intentionally manages Helm deployments through OpenTofu's Helm provider, which does not require the `helm` CLI binary. Classifying the CLI's absence as a critical failure caused unnecessary playbook failures on clean deployments. The detail message was updated to explain why the CLI is absent.

---

## 9. Verification <a name="verification"></a>

After all changes were applied, the readiness check playbook was re-run:

```bash
cd /vagrant/ansible
set -a; source /vagrant/.env; set +a
ansible-playbook playbooks/readiness_check.yml
```

**Result:**
```
Total Checks: 23 | Passed: 21 | Warned: 2 | Failed: 0

STATUS: ⚠️  Environment is mostly ready, but review warnings above.
```

```
PLAY RECAP
localhost: ok=64  changed=0  unreachable=0  failed=0  skipped=16  rescued=0  ignored=0
```

The two remaining warnings are expected:
1. **Helm CLI not installed** — expected, OpenTofu manages charts
2. **DNS resolution for armory.local** — expected, no hosts file entry in the VM itself

All other 21 checks passed, including HTTPS connectivity which now returns 307 (the signin redirect) instead of 502.

---

## 10. Background Concepts for Non-Technical Readers <a name="background-concepts"></a>

This section explains the technical concepts involved in plain language.

### What is a Pod?

In Kubernetes, a "pod" is the smallest deployable unit — essentially one or more containers running together on the same machine. Each pod gets its own private IP address, like a mini-machine within the cluster. In this system, `agentstack-ui` is a pod running the Next.js web frontend.

### What is a Bridge (cni0)?

A "bridge" is a software Ethernet switch built into the Linux kernel. Just like a physical network switch connects multiple computers so they can talk to each other, the `cni0` bridge connects all the pods running on the same machine. Each pod is connected to the bridge via a "veth pair" — think of it as a virtual Ethernet cable where one end is plugged into the pod and the other end is plugged into the switch.

### What is a Veth Pair?

A "veth pair" is like a virtual cable with two ends. One end lives inside the pod (called `eth0` inside the pod). The other end lives on the host machine (given a name like `veth685ecc2e`). Data sent into one end comes out the other. The host end is plugged into the `cni0` bridge/switch.

### What is iptables / nftables?

These are Linux kernel mechanisms for filtering network packets — essentially the host machine's built-in firewall. Rules can be written like "if a packet comes from IP X going to port Y, accept it" or "... drop it." iptables is the older interface; nftables is the newer replacement. On modern Fedora, both exist simultaneously, and both process traffic.

### What is firewalld?

firewalld is a management tool that provides a friendlier interface for configuring nftables rules. Instead of writing raw nftables syntax, administrators can say "put these IP ranges in the `trusted` zone" and firewalld translates that into the appropriate nftables rules.

### What is a Firewalld Zone?

A "zone" is a firewalld concept representing a level of trust. Different zones have different default policies:
- `public` — external-facing networks; minimal trust; only explicitly allowed traffic passes
- `trusted` — completely trusted networks; all traffic is allowed

When you assign an IP range (like `10.42.0.0/16`) to the `trusted` zone, firewalld treats all traffic from those IPs as trusted.

### What is the FORWARD Hook?

The Linux kernel has several "hooks" — points where network packets can be intercepted and filtered. The important ones are:
- **INPUT** — for packets destined for the machine itself
- **OUTPUT** — for packets originating from the machine itself
- **FORWARD** — for packets that are *passing through* the machine from one network interface to another

Normally, pod-to-pod traffic wouldn't need to be "forwarded" — it stays within the bridge (like traffic within a switch stays within the switch). But because Kubernetes enables `net.bridge.bridge-nf-call-iptables`, the bridge is configured to also submit bridged traffic to the FORWARD hook, so Kubernetes network policies can inspect and control pod-to-pod traffic.

### What is DNAT?

DNAT (Destination Network Address Translation) is when the kernel rewrites the destination IP address of a packet in transit. Kubernetes uses DNAT to implement "services": when you connect to a service's virtual IP (`10.43.x.x`), the kernel rewrites the destination to the actual pod IP. This is transparent to the connecting application.

The significance here is that DNAT'd traffic is tracked (via connection tracking with `ct status dnat`) and was explicitly allowed by firewalld. Direct pod-IP connections (used by nginx ingress) are NOT DNAT'd and were not explicitly allowed.

### What is netfilter Priority?

When multiple firewall rules exist, they run in order of "priority" — a number where lower numbers run first. iptables (kube-router) runs at priority 0. firewalld (nftables) runs at priority 10. When iptables says "accept this packet," it doesn't stop firewalld from also evaluating the packet — they're independent, and both run. This is why iptables accepting a packet didn't prevent firewalld from also rejecting it.

---

## 11. Recurrence and Prevention <a name="recurrence-and-prevention"></a>

### Will This Break Again on the Next Full Playbook Run?

No. The playbook changes ensure that on all subsequent runs, the pod and service CIDRs are added to the `trusted` zone (not `public`). Because firewalld rules are idempotent in Ansible (the `ansible.posix.firewalld` module checks before applying), re-running the playbook will confirm the rules are present rather than re-adding them.

If a full teardown and rebuild occurs (firewalld rules cleared), the next `ansible-playbook playbooks/site.yml` run will correctly add the CIDRs to the trusted zone as part of the `k3s` role's firewall tasks.

### Situations That Could Cause Recurrence

1. **Manual firewalld reset:** Running `sudo firewall-cmd --complete-reload` or reinstalling firewalld clears all zone assignments. The playbook must be re-run to restore them.
2. **OS upgrade changing firewalld defaults:** Major Fedora version upgrades may reset zone configurations. Re-run the playbook after OS upgrades.
3. **Changing `k3s_pod_cidr` or `k3s_service_cidr`:** If these are changed in the playbook, the new CIDRs must be added to the trusted zone, and the old CIDRs should be removed from any zone. The playbook handles addition but does not remove old entries.

### What to Check if 502s Return

1. `sudo k3s kubectl logs -n ingress-nginx <nginx-pod> --tail=20` — look for `(113: Host is unreachable)`
2. `sudo firewall-cmd --zone=trusted --list-sources` — verify `10.42.0.0/16 10.43.0.0/16` appear
3. `sudo nft list chain inet firewalld filter_FORWARD_POLICIES | grep trusted` — verify trusted zone rules are in nftables
4. `sudo nsenter -t <pod-pid> -n -- ping -c 2 <other-pod-ip>` — test pod-to-pod ICMP; "Packet filtered" = firewalld issue

### Monitoring Command

Quick check that the fix is active in runtime (returns lines if correct):

```bash
sudo nft list chain inet firewalld filter_FORWARD_POLICIES | grep "10.42.0.0/16.*trusted"
```

Expected output (at minimum):
```
ip saddr 10.42.0.0/16 jump filter_FWD_trusted
ip saddr 10.42.0.0/16 accept
```

---

*Document created: 2026-05-12. Last updated: 2026-05-12.*
