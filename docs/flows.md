# The two flows

The demo is built around the distinction the request called out: the **first time**
you deliver everything; **afterwards** you usually just update ACLs.

## Flow 1 — First-time onboarding ("deliver everything")

Template: **Consume Kafka Topics**. Produces a full tenant directory and, combined
with the platform bootstrap, stands up the whole path.

```mermaid
sequenceDiagram
  autonumber
  participant Dev as App developer
  participant BS as Backstage
  participant Git as Git repo
  participant Argo as Argo CD
  participant KO as Kong Operator
  participant KEG as Event Gateway
  Dev->>BS: Pick provider + topics + auth (SCRAM)
  BS->>Git: PR adds gitops/apps/<app>/ (VC, ACL, TLSRoute, Secret)
  Dev->>Git: Review + merge
  Git->>Argo: ApplicationSet detects new tenant dir
  Argo->>KO: Apply CRDs
  KO->>KEG: Create virtual cluster, principal, ACLs, route
  Dev->>KEG: Connect (SASL_SSL/SCRAM) and consume
```

What "deliver everything" covers:

- **Platform** (`platform/`, applied once via `platform-app.yaml` or `kubectl -k`):
  Konnect control plane, Event Gateway data plane, shared listener + TLS + SNI
  routing, the Kubernetes Gateway, and the backing Kafka cluster + topics.
- **Per app** (the Backstage PR): the virtual cluster, credentials, ACLs and route.

## Flow 2 — Add topics later ("just update the ACLs")

Template: **Add Topics to Application**. Regenerates only
`gitops/apps/<app>/kong/acl-policy.yaml`. The virtual cluster, credentials and route
are untouched, so the app keeps the same bootstrap endpoint and the same credential.

```mermaid
sequenceDiagram
  autonumber
  participant Dev as App developer
  participant BS as Backstage
  participant Git as Git repo
  participant Argo as Argo CD
  participant KEG as Event Gateway
  Dev->>BS: Re-select the full topic set for <app>
  BS->>Git: PR touches only acl-policy.yaml
  Dev->>Git: Review + merge
  Git->>Argo: Sync (one CRD changes)
  Argo->>KEG: Updated ACL rules
  Dev->>KEG: New topics now readable, same credential/endpoint
```

## Why this split matters

- The expensive, privileged, one-time work (control plane, data plane, backing
  cluster, certificate) is isolated in `platform/` and never re-run per request.
- The frequent, low-risk work (granting a topic) is a single-file diff a data owner
  can approve in seconds — the smallest possible blast radius.
