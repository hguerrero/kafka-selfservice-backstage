# Kafka Self-Service with Backstage + Kong Event Gateway

A runnable demo of **developer self-service for Apache Kafka**. Application teams
discover available topics in Backstage (published as AsyncAPI), then use a scaffolder
template to request access. Behind the form, Kong Event Gateway gets a dedicated
**virtual cluster** for the app, **SCRAM (or OAuth) credentials**, and **ACLs** scoped
to exactly the topics requested — delivered via GitOps and reconciled by the **Kong
Operator** on Kubernetes.

> The first request delivers everything (control plane, data plane, credentials,
> ACLs, routing). Later requests usually just update the ACLs to add more topics.

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
│   ├── networking/          #   GatewayClass/Config, Gateway, TLS cert
│   ├── backstage/           #   in-cluster Backstage: Deployment, Service, Postgres, config
│   └── kafka/               #   Strimzi Kafka cluster + topics
├── gitops/
│   ├── argocd/              # platform App + tenants ApplicationSet
│   └── apps/                # one dir per onboarded app (Backstage writes here)
│       └── fraud-analytics/ #   worked example (rendered output)
├── examples/kafka-client/   # SCRAM client config + test commands
├── scripts/                 # bootstrap, cert, validate
└── docs/                    # architecture.md, flows.md
```

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

**Argo CD** — reconciles `platform/` and auto-onboards each `gitops/apps/*` tenant:

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
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
# exposed through the same Kong Gateway (web listener + HTTPRoute); with minikube tunnel:
#   http://backstage.127-0-0-1.sslip.io
```

Kong Operator + Strimzi install commands (and the AsyncAPI page wiring) are also in
[`docs/prerequisites.md`](docs/prerequisites.md).

## Quick start

```bash
# 1) Platform (control plane, data plane, Kafka, routing)
export KONNECT_PAT=kpat_xxx
./scripts/bootstrap.sh

# 2) Either let Argo CD manage tenants...
kubectl apply -f gitops/argocd/            # edit repoURL first
# ...or apply the worked example directly:
kubectl apply -k gitops/apps/fraud-analytics/kong/

# 3) Expose the gateway locally and test
minikube tunnel &
cat examples/kafka-client/test-commands.md
```

To wire up the portal, register `catalog-info.yaml` in Backstage and merge
`backstage/app-config.snippet.yaml` into your `app-config.yaml`.

## The self-service experience

1. A developer opens the **Retail Banking NY** or **Wealth Management LA** API in the
   Backstage catalog and reads the AsyncAPI channels (topics).
2. They run **Consume Kafka Topics**, name their app, pick topics, and choose SCRAM or
   OAuth. Backstage opens a PR under `gitops/apps/<app>/`.
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

- Kong Operator CRD field names for Event Gateway are evolving. The virtual cluster
  `apiSpec` mirrors the Konnect / `kongctl` schema. Two spots to confirm against the
  CRDs in *your* operator version: the SCRAM principal **password secret-ref** shape,
  and whether ACLs are a separate `EventGatewayVirtualClusterPolicy` or inline on the
  virtual cluster (`spec.apiSpec.clusterPolicies`). Both are called out in comments.
- SCRAM passwords are placeholders (`REPLACE_ME`). For real use, generate them with a
  custom scaffolder action and store via SealedSecrets / External Secrets — never
  commit plaintext.
- The `platform/` Kafka + Event Gateway manifests are adapted from the
  `kong-event-gw-kubernetes` reference.

## References

- [Kong Event Gateway](https://developer.konghq.com/event-gateway/)
- [Productize Kafka topics with namespaces and ACLs](https://developer.konghq.com/event-gateway/productize-kafka-topics/)
- [Event Gateway with Kong Identity OAuth + ACLs](https://developer.konghq.com/how-to/event-gateway/kong-identity-oauth/)
- [Kong Operator](https://developer.konghq.com/operator/)
- [Backstage software templates](https://backstage.io/docs/features/software-templates/)
