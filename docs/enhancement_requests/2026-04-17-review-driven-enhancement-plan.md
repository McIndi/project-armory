# Review-Driven Enhancement Plan

Date: 2026-04-17
Project: Project Armory
Source inputs: repository review, README warnings/advice, and accepted ADRs

## Purpose

This document turns the review suggestions into concrete enhancement requests and evaluates whether each change is worth the trade-off in the context of the project's existing decisions.

## Decision Summary

| ID | Suggestion | ADR / README alignment | Recommendation |
|----|------------|------------------------|----------------|
| ER-001 | Tighten secret and directory permissions | Partially conflicts with ADR-005 and README security trade-offs if done as a default | **Pursue only as an opt-in hardening mode** |
| ER-002 | Make test bootstrap fully self-contained | Strongly aligned with ADR-015 | **Pursue now** |
| ER-003 | Improve health checks and webserver certificate flexibility | Strongly aligned with ADR-016 and compatible with ADR-007 | **Pursue now** |
| ER-004 | Replace shell-heavy orchestration wholesale | Weak trade-off given ADR-008, ADR-011, and current portability goals | **Defer / not advisable now** |
| ER-005 | Speed up repeated apply and test cycles | Acceptable only if optional; default behavior should remain per ADR-015 | **Pursue as an opt-in developer mode** |
| ER-006 | Surface demo-vs-production warnings earlier | Strongly aligned with README guidance and ADR-012 | **Pursue now** |

---

## ER-001 — Optional hardened filesystem and secret handling

### Description
Introduce an optional hardening profile for deployments on shared or semi-trusted hosts, while preserving the current default demo behavior.

### Why this is worth it
- The README already warns that local state and key files are a meaningful exposure on shared hosts.
- ADR-005 accepts world-readable TLS artifacts primarily for portability and rootless runtime compatibility.
- ADR-012 accepts plaintext local state as a demo limitation, not as a production pattern.

### Trade-off evaluation
**Default change:** not advisable.

Changing the default permissions would work against a deliberate portability decision in ADR-005 and may break rootless Podman behavior across environments.

**Opt-in hardening mode:** advisable.

An opt-in mode respects the ADRs while giving operators a better path when the host trust model is stricter.

### Strategy
1. Add a variable such as `security_profile = "demo" | "hardened"` or a boolean such as `hardened_filesystem = false`.
2. Keep today's permissions and file layout as the demo default.
3. In hardened mode:
   - tighten directory permissions where container access allows it,
   - prefer least-privilege group readability over world readability where feasible,
   - document unsupported combinations clearly,
   - add a warning if the operator keeps local state on disk without remote encryption.
4. Update the README to explain that hardened mode reduces local exposure but does **not** solve the tfstate plaintext limitation.

### Files affected
- `vault/main.tf`
- `services/webserver/main.tf`
- `README.md`
- Possibly `docs/ADR/ADR-005-world-readable-tls-artifacts.md` if the hardening mode becomes an accepted extension

### Rollback if the fix does not work
- Leave the new variable disabled by default.
- Revert to the current permission model on any host where the hardened mode blocks container startup.
- Treat hardened mode as experimental until verified on both rootless and rootful Podman.

### Notes
This should be framed as a **compatibility-preserving enhancement**, not as a repudiation of ADR-005.

---

## ER-002 — Self-contained integration test bootstrap

### Description
Make the test suite initialize everything it needs from a clean checkout without relying on prior manual `tofu init` runs.

### Why this is worth it
- ADR-015 explicitly values one-command end-to-end validation and low operator friction.
- This has a high reliability payoff and very low design risk.
- It improves CI portability and reduces “works on my machine” failures.

### Trade-off evaluation
Strong trade-off. This is advisable and consistent with the project's testing philosophy.

### Strategy
1. Ensure `tofu init` runs for every module the fixture touches before `apply` or `destroy`.
2. Fail early with a clearer error if Podman or OpenTofu are unavailable.
3. Keep the existing full destroy-rebuild flow as the default behavior.
4. Preserve log collection and the `ARMORY_NO_TEARDOWN` behavior.

### Files affected
- `tests/conftest.py`
- `README.md`
- Possibly module test docs if command examples change

### Rollback if the fix does not work
- Revert to the existing fixture flow.
- Keep the current test contract and only retain any added error messages that proved useful.

### Notes
This is the safest and highest-value enhancement from the review.

---

## ER-003 — Stronger readiness checks and flexible service certificate SANs

### Description
Improve the service startup checks so that they verify actual HTTPS readiness rather than only the presence of a rendered PEM file. At the same time, make SAN inputs more configurable for non-loopback access.

### Why this is worth it
- ADR-016 establishes the sidecar pattern and automatic certificate delivery. Better health checks make that pattern more trustworthy.
- ADR-007 keeps Vault localhost-only without forbidding service publication patterns; this change does not violate that decision.
- The README already discusses local versus broader network access, so clearer SAN control is aligned with operator needs.

### Trade-off evaluation
Strong trade-off. This is advisable and should improve reliability without changing the architecture.

### Strategy
1. Replace the vault-agent healthcheck condition of “file exists” with a stronger readiness condition where practical.
2. Add configurable SAN inputs for service certificates so hostnames and IPs beyond loopback can be requested intentionally.
3. Extend tests to cover the intended certificate naming behavior.
4. Document the constraints clearly in the README.

### Files affected
- `services/webserver/templates/compose.yml.tpl`
- `services/webserver/templates/agent.hcl.tpl`
- `services/webserver/variables.tf`
- `tests/test_webserver.py`
- `README.md`

### Rollback if the fix does not work
- Fall back to the current file-based healthcheck.
- Keep SAN settings at their current default so existing local behavior remains unchanged.

### Notes
This should remain narrowly scoped. It is a reliability enhancement, not a redesign of the Vault Agent pattern.

---

## ER-004 — Reduce shell-heavy orchestration

### Description
Reassess whether the current Podman lifecycle and filesystem setup should be moved away from `local-exec` and shell commands.

### Why this may not be worth it right now
- ADR-008 already moved Vault configuration into the provider-backed declarative path, which solved the highest-value shell problem.
- ADR-011 favors separate modules and simple operational sequencing.
- The remaining shell use is mostly host runtime orchestration, which currently has no equally portable provider-native substitute.

### Trade-off evaluation
**Weak trade-off for a full rewrite. Not advisable now.**

A broad refactor would introduce churn and risk without a proportional gain in security or functionality. It may also reduce runtime portability across Podman modes.

### Strategy
Do **not** pursue a large rewrite now. If maintainability pain grows later, limit the change to small improvements:
1. centralize repeated command snippets,
2. add comments around why `podman unshare` is required,
3. improve operator-facing error messages.

### Files affected
If a limited follow-up is approved later:
- `vault/main.tf`
- `services/webserver/main.tf`
- `README.md`

### Rollback if the fix does not work
- Keep the current orchestration model unchanged.
- Revert any helper abstraction that makes failures harder to diagnose.

### Notes
This is a good candidate for **defer**, not for immediate engineering time.

---

## ER-005 — Faster developer loop without weakening default test guarantees

### Description
Introduce optional fast-path behavior for local iteration while preserving the current full rebuild path as the default verification mode.

### Why this is worth it only as an option
- ADR-015 explicitly accepts slower runs in exchange for full end-to-end confidence.
- The README presents the integration suite as a destroy-rebuild-validate cycle; changing that default would weaken the stated assurance.

### Trade-off evaluation
**Moderate trade-off as opt-in. Weak as a default change.**

Optional speedups are worthwhile for developer ergonomics, but they must not replace the full validation path.

### Strategy
1. Add opt-in environment flags for local iteration only, such as:
   - skip image pulls when images are already present,
   - keep the environment running between runs,
   - skip the cold-start rebuild when explicitly requested.
2. Keep the existing one-command “full confidence” flow as the documented default.
3. Add a short README section that explains when fast mode is safe to use.

### Files affected
- `tests/conftest.py`
- `vault/main.tf`
- `services/webserver/main.tf`
- `README.md`

### Rollback if the fix does not work
- Disable the fast path and continue using the current default behavior.
- Remove any optimization that causes flaky or non-reproducible results.

### Notes
This enhancement should be treated as a developer convenience feature, not as a replacement for the full integration suite.

---

## ER-006 — Earlier and clearer demo-vs-production guidance

### Description
Move the strongest operational warnings closer to the top of the project docs so that users understand the trust model before deployment.

### Why this is worth it
- This aligns directly with the README’s existing warnings and ADR-012.
- It reduces the risk of accidental misuse with almost no downside.
- It improves maintainability by making the project’s assumptions explicit for future contributors.

### Trade-off evaluation
Very strong trade-off. Advisable now.

### Strategy
1. Add a prominent “local demo / learning environment” callout near the top of the README.
2. Link directly to the existing security trade-offs section and the relevant ADRs.
3. Make the production path explicit: remote encrypted state, restricted host access, and stronger operational controls.

### Files affected
- `README.md`
- Optionally `docs/ADR/README.md`

### Rollback if the fix does not work
- Remove or shorten the callout if it becomes too repetitive.
- Keep the underlying warnings elsewhere in the README.

### Notes
This is a documentation-only improvement with near-zero technical risk.

---

## Recommended implementation order

### Phase 1 — pursue now
1. ER-002 — self-contained test bootstrap
2. ER-003 — stronger readiness and SAN flexibility
3. ER-006 — earlier demo-vs-production guidance

### Phase 2 — pursue only as opt-in features
4. ER-001 — hardened filesystem mode
5. ER-005 — faster local developer mode

### Phase 3 — defer
6. ER-004 — large shell/orchestration refactor

## Final recommendation

The review suggestions hold up well overall, but **not all of them should become default behavior**.

The best near-term changes are the ones that improve reliability and clarity without undermining the deliberate demo-oriented trade-offs already recorded in the ADRs:
- make tests more self-contained,
- strengthen readiness checks and cert flexibility,
- improve the visibility of the existing warnings.

Security hardening and speedups are still worthwhile, but only when introduced as explicit, opt-in modes. A broad rewrite away from the current host orchestration model is not justified at this stage.
