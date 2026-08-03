# Installing prerequisites

Everything below assumes a running Kubernetes cluster and `kubectl` pointed at it.
For a laptop demo, `minikube start --cpus=4 --memory=8192` is enough. Install order
doesn't matter much, but cert-manager before the platform is convenient (the Event
Gateway TLS listener consumes a cert-manager `Certificate`).

Versions move quickly — the commands below track the projects' "latest/stable"
channels. Pin to a specific release for anything beyond a demo.

## 1. cert-manager

Issues the wildcard TLS certificate (`keg-tls-secret`) that the Event Gateway
listener terminates. One manifest installs the CRDs and all components into the
`cert-manager` namespace.

```bash
# Latest release:
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
# (or pin, e.g. .../releases/download/v1.21.1/cert-manager.yaml)

# Wait until it's ready:
kubectl wait --for=condition=Available --timeout=180s \
  -n cert-manager deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector
```

This repo's `platform/networking/tls-certificate.yaml` then creates a self-signed
`Issuer` + wildcard `Certificate`. No cert-manager? Skip that file and run
`./scripts/generate-cert.sh` instead to create the secret with openssl.

## 2. Argo CD

Drives GitOps: it reconciles `platform/` and auto-onboards each tenant under
`gitops/apps/*` via the ApplicationSet.

```bash
kubectl create namespace argocd
# --server-side is required: the ApplicationSet CRD exceeds the client-side apply limit.
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=Available --timeout=300s \
  -n argocd deployment/argocd-server deployment/argocd-applicationset-controller
```

Access the UI and get the initial admin password:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# user: admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Then point Argo CD at your fork and let it manage everything:

```bash
# Edit the repoURL in these files first, then:
kubectl apply -f gitops/argocd/platform-app.yaml     # reconciles platform/
kubectl apply -f gitops/argocd/tenants-appset.yaml   # one App per gitops/apps/*
```

If you're not using Argo CD, apply the platform and tenants directly instead:
`kubectl apply -k platform/` and `kubectl apply -k gitops/apps/<app>/kong/`.

## 3. Backstage (in-cluster)

Backstage hosts the streams catalog (AsyncAPI) and the self-service templates. It
runs **inside the cluster** in the `backstage` namespace. Manifests are provided in
`platform/backstage/` (Deployment, Service, ConfigMap app-config, Postgres, Secret).

Backstage has no generic public image — you build one from a `create-app` project,
bake in the AsyncAPI plugin, then deploy that image with the provided manifests.

### 3a. Scaffold the app and add the AsyncAPI plugin

Requires Node.js Active LTS and Yarn (local, just to build the image).

```bash
npx @backstage/create-app@latest        # creates ./my-backstage-app
cd my-backstage-app
yarn --cwd packages/app add @backstage/plugin-api-docs @asyncapi/backstage-plugin
```

Wire the AsyncAPI renderer into the API entity page: in
`packages/app/src/components/catalog/EntityPage.tsx`, add an AsyncAPI tab gated on
`spec.type === 'asyncapi'` (see the plugin README for the `AsyncApiDefinitionWidget`
import). You do **not** need to hand-edit `app-config.yaml` for the catalog/GitHub
settings — those come from the in-cluster ConfigMap and Secret below.

### 3b. Build and push the image

`create-app` scaffolds `packages/backend/Dockerfile`. Build the backend bundle, then
the image:

```bash
yarn install --immutable
yarn tsc
yarn build:backend
docker build . -f packages/backend/Dockerfile -t your-registry/backstage:latest
docker push your-registry/backstage:latest
```

For a local minikube demo you can skip the registry and load the image directly:

```bash
minikube image load your-registry/backstage:latest
```

Set that image name in `platform/backstage/deployment.yaml` (the `image:` field).

### 3c. Configure

Edit two files in `platform/backstage/`:

- `backstage-secrets.yaml` — set `POSTGRES_PASSWORD`, `GITHUB_TOKEN` (PAT/App token
  with `repo` + PR scope, since the templates open pull requests), and
  `BACKEND_SECRET` (`openssl rand -base64 32`). Use SealedSecrets / External Secrets
  for anything real — don't commit plaintext.
- `app-config.configmap.yaml` — point `catalog.locations[].target` at your fork's
  `catalog-info.yaml`. This is what the in-cluster app reads (it replaces
  `backstage/app-config.snippet.yaml`, which remains as a reference for the config
  keys).

### 3d. Deploy

```bash
kubectl apply -k platform/backstage/
kubectl -n backstage rollout status deployment/backstage
```

Or let Argo CD manage it by adding `platform/backstage` to the platform Application
(it's excluded from the default `platform/kustomization.yaml` because it needs your
image built first).

### 3e. Access

Backstage is exposed through the **same Kong Gateway** as the Kafka traffic, via the
`web` HTTP listener on `kong-keg` and `platform/backstage/httproute.yaml` (both applied
already by the steps above). With `minikube tunnel` running:

```bash
# backstage.127-0-0-1.sslip.io resolves to 127.0.0.1 -> Kong :80 -> Backstage :7007
open http://backstage.127-0-0-1.sslip.io
```

Prefer no Gateway? You can still port-forward directly and set both `app.baseUrl` and
`backend.baseUrl` in the ConfigMap to `http://localhost:7007`:

```bash
kubectl -n backstage port-forward svc/backstage 7007:7007
```

Both self-service templates and both AsyncAPI APIs load automatically from the
catalog Location. If you'd rather register manually, use **Create → Register Existing
Component** in the UI and paste your fork's `catalog-info.yaml` URL.

## 4. Kong Operator & Strimzi (cluster-side platform)

Needed before applying `platform/`. Summarized here; `scripts/bootstrap.sh` runs the
Strimzi + secret steps for you.

```bash
# Strimzi (Kafka operator) into the kafka namespace:
kubectl create namespace kafka
kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# Kong Operator via Helm (see https://developer.konghq.com/operator/ for current chart):
helm repo add kong https://charts.konghq.com && helm repo update
kubectl create namespace kong
helm install kong-operator kong/kong-operator -n kong

# Konnect auth secret used by every Event Gateway CRD:
kubectl create secret generic konnect-api-auth-secret \
  --from-literal=token="$KONNECT_PAT" -n kong
```

## Verify the toolchain

```bash
kubectl get pods -n cert-manager
kubectl get pods -n argocd
kubectl get pods -n kong
kubectl get pods -n kafka
```

Once these are healthy, follow the Quick start in the [README](../README.md).
