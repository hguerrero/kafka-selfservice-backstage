# Kafka Self-Service with Backstage + Kong Event Gateway

A runnable demo of **developer self-service for Apache Kafka**. Application teams
discover available topics in Backstage (published as AsyncAPI), then use a scaffolder
template to request access. Behind the form, Kong Event Gateway gets a dedicated
**virtual cluster** for the app, **credentials (SASL username + password, or OAuth)**, and **ACLs** scoped
to exactly the topics requested — delivered via GitOps and reconciled by the **Kong
Operator** on Kubernetes.

> The first request delivers everything (control plane, data plane, credentials,
> ACLs, routing). Later requests usually just update the ACLs to add more topics.

> **Two repos.** This is the **portal/platform** repo (catalog, templates, platform
> bootstrap). Tenant GitOps config lives in a companion repo,
> [`kafka-selfservice-gitops`](https://github.com/your-org/kafka-selfservice-gitops):
> the templates open PRs there and Argo CD watches it. See
> [`docs/repositories.md`](docs/repositories.md).

## Why it's interesting

- **Zero broker changes to grant access.** Credentials are terminated at the gateway
  (`mediation: terminate`), so you never create Kafka users or Kafka-side ACLs.
- **Default-deny, per-app isolation.** Each app is its own virtual cluster in
  `enforce_on_gateway` mode; access is only what the ACL policy allows.
- **Stable logical topic names.** The `RETAIL_NY.` / `WEALTH_LA.` broker prefixes are
  hidden via namespace mediation.
- **GitOps end to end.** Backstage opens a PR; Argo CD + Kong Operator do the rest.

## Repository layout

```
├── catalog/                 # Backstage: AsyncAPI specs + API/System/Domain/Group entities
│   ├── specs/               #   AsyncAPI 3.0 documents (the "available topics")
│   └── apis/                #   API entities of type asyncapi
├── backstage/
│   ├── templates/
│   │   ├── consume-kafka-topics/   # Flow 1: full onboarding
│   │   └── add-topics-to-app/      # Flow 2: ACL-only update
│   └── app-config.snippet.yaml     # how to wire this into your Backstage
├── platform/                # "Deliver everything" bootstrap (applied once)
│   ├── event-gateway/       #   Konnect CP, backend cluster, listener, KNEP data plane
│   ├── networking/          #   GatewayClass/Config, Gateway (Kafka + web listeners), TLS cert
│   ├── backstage/           #   in-cluster Backstage: Deployment, Service, Postgres, config
│   ├── argocd/              #   Argo CD route through the Kong Gateway (+ insecure mode)
│   └── kafka/               #   Strimzi Kafka cluster + topics
├── examples/kafka-client/   # SASL/PLAIN client config + test commands
├── scripts/                 # bootstrap, cert, validate
└── docs/                    # architecture, flows, prerequisites, secrets, repositories
```

Tenant config (the `apps/*` directories Backstage writes to, plus the Argo CD
`ApplicationSet`) lives in the companion **`kafka-selfservice-gitops`** repo, not here.

## Prerequisites

- A Kubernetes cluster (minikube is fine) with **Kong Operator**, **Strimzi**,
  **cert-manager** and **Argo CD** installed.
- A **Konnect** account + Personal Access Token (`KONNECT_PAT`).
- **Backstage** runs in-cluster (manifests in `platform/backstage/`); you build its
  image once from a `create-app` project.

### Installing the prerequisites

Full step-by-step commands are in [`docs/prerequisites.md`](docs/prerequisites.md).
The essentials:

**cert-manager** — issues the wildcard TLS cert the Event Gateway listener uses:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

**Argo CD** — reconciles `platform/` (this repo) and auto-onboards each tenant from
the companion repo's `apps/*`:

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# then apply argocd/platform-app.yaml + argocd/tenants-appset.yaml from
# the kafka-selfservice-gitops repo (edit repoURLs first).
```

**Backstage** — runs in-cluster; build the image once, then deploy the manifests:

```bash
# 1) scaffold + add the AsyncAPI plugin, build and push an image
npx @backstage/create-app@latest && cd my-backstage-app
yarn --cwd packages/app add @backstage/plugin-api-docs @asyncapi/backstage-plugin
yarn install --immutable && yarn tsc && yarn build:backend
docker build . -f packages/backend/Dockerfile -t your-registry/backstage:latest
docker push your-registry/backstage:latest   # or: minikube image load ...

# 2) set the image + secrets, then deploy into the cluster
#    (edit platform/backstage/deployment.yaml image, backstage-secrets.yaml,
#     and the catalog location in app-config.configmap.yaml)
kubectl apply -k platform/backstage/
# exposed over HTTPS through the same Kong Gateway (web listener + HTTPRoute);
# with minikube tunnel: https://backstage.127-0-0-1.sslip.io (accept the self-signed cert)
```

Kong Operator + Strimzi install commands (and the AsyncAPI page wiring) are also in
[`docs/prerequisites.md`](docs/prerequisites.md).

## Quick start

```bash
# 1) Platform (control plane, data plane, Kafka, routing)
export KONNECT_PAT=kpat_xxx
./scripts/bootstrap.sh

# 2) Tenants come from the companion repo (kafka-selfservice-gitops):
#    let Argo CD manage them...
kubectl apply -f ../kafka-selfservice-gitops/argocd/   # edit repoURLs first
#    ...or apply the worked example directly:
kubectl apply -k ../kafka-selfservice-gitops/apps/fraud-analytics/kong/

# 3) Expose the gateway locally and test
minikube tunnel &
# UIs are routed over HTTPS through the Kong Gateway (self-signed cert, accept warning):
#   Backstage -> https://backstage.127-0-0-1.sslip.io
#   Argo CD   -> https://argocd.127-0-0-1.sslip.io
#   (first time only: kubectl -n argocd rollout restart deployment/argocd-server)
cat examples/kafka-client/test-commands.md
```

To wire up the portal, point the in-cluster Backstage `catalog.locations` at this
repo's `catalog-info.yaml` (see `platform/backstage/app-config.configmap.yaml`).

## The self-service experience

1. A developer opens the **Retail Banking NY** or **Wealth Management LA** API in the
   Backstage catalog and reads the AsyncAPI channels (topics).
2. They run **Consume Kafka Topics**, name their app, pick topics, and choose
   SASL/PLAIN or OAuth. Backstage opens a PR adding `apps/<app>/` to the
   `kafka-selfservice-gitops` repo.
3. On merge, Argo CD + Kong Operator provision the virtual cluster, credentials, ACLs
   and route. The app connects to `bootstrap.<app>.127-0-0-1.sslip.io:9092`.
4. Need more topics later? **Add Topics to Application** changes only the ACL policy.

See [`docs/flows.md`](docs/flows.md) for sequence diagrams and
[`docs/architecture.md`](docs/architecture.md) for the component model.

## Validate

```bash
./scripts/validate.sh   # yamllint + kubeconform + asyncapi validate
```

## Notes & caveats

- Auth mechanism: the Kong Operator CRD's `saslScram` type does **not** accept inline
  username/password (it only carries `algorithm` and resolves principals via Kong
  Identity). So the self-contained "issue a user + password, validated and terminated
  at the gateway" model uses **`saslPlain`** (`type: saslPlain` + a sibling `saslPlain`
  object with `mediation: terminate` and `principals[]`). Native SCRAM or OAuth via
  Kong Identity is the enterprise path. Auth and ACL manifests match the installed CRD
  schema (`configuration.konghq.com/v1alpha1`): auth is a discriminated union, and ACL
  rules use `resourceType` / `operations: [{name}]` / `resourceNames: {type: stat, stat: [{match}]}`.
- Credentials (and the Backstage/Konnect secrets) are placeholders (`REPLACE_ME`).
  For real use, use a secret-template / Konnect vault reference for the SASL password,
  and store Kubernetes secrets via Sealed Secrets or External Secrets — never commit
  plaintext. [`docs/secrets.md`](docs/secrets.md) shows worked manifests.
- The `platform/` Kafka + Event Gateway manifests are adapted from the
  `kong-event-gw-kubernetes` reference.

## References

- [Kong Event Gateway](https://developer.konghq.com/event-gateway/)
- [Productize Kafka topics with namespaces and ACLs](https://developer.konghq.com/event-gateway/productize-kafka-topics/)
- [Event Gateway with Kong Identity OAuth + ACLs](https://developer.konghq.com/how-to/event-gateway/kong-identity-oauth/)
- [Kong Operator](https://developer.konghq.com/operator/)
- [Backstage software templates](https://backstage.io/docs/features/software-templates/)
