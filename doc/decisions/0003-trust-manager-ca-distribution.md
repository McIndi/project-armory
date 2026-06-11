# 0003 — Declarative CA distribution via trust-manager

Status: implemented (toggle `use_declarative_ca_distribution: true`)
Source: [../simplification-opportunities.md](../simplification-opportunities.md) #1

## Context

Every VSO consumer namespace needs the OpenBao CA. Originally each role
copied the `openbao-ca` Secret via a ~6-task sequence (read, temp file,
`kubectl create secret --dry-run | apply`, cleanup), repeated per namespace.

## Decision

Deploy trust-manager (cert-manager subproject) with one `Bundle` that
distributes the CA to the consumer namespaces as the `openbao-ca-bundle`
Secret. Exception: cert-manager itself always self-bootstraps from the
direct `openbao-ca` copy, because it runs before trust-manager and anchors
the trust chain — anything else is circular.

## Consequences

New namespaces get the CA declaratively; the per-role copy dances are gone
for consumers. One extra small controller in-cluster. Rollback path: flip
`use_declarative_ca_distribution: false`.
