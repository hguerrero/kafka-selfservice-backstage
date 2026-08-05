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

Drives GitOps: it reconciles this repo's `platform/` and auto-onboards each tenant
from the companion `kafka-selfservice-gitops` repo's `apps/*` via the ApplicationSet.
See [`repositories.md`](repositories.md) for the two-repo layout.

```bash
kubectl create namespace argocd
# --server-side is required: the ApplicationSet CRD exceeds the client-side apply limit.
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=Available --timeout=300s \
  -n argocd deployment/argocd-server deployment/argocd-applicationset-controller
```

Get the initial admin password:

```bash
# user: admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

The platform bundle ships an **Argo CD route** through the Kong Gateway
(`platform/argocd/`), so once the platform is applied you reach the UI at
`https://argocd.127-0-0-1.sslip.io` (with `minikube tunnel` running) — no port-forward.
TLS is terminated at the gateway with the wildcard cert; it's self-signed, so accept
the browser warning. The route sets argocd-server to insecure (plain HTTP) behind the
gateway, which needs a one-time restart the first time it's applied:

```bash
kubectl -n argocd rollout restart deployment/argocd-server
```

Before the route exists (e.g. first login), you can still port-forward:
`kubectl -n argocd port-forward svc/argocd-server 8080:443`.

Then apply the Argo manifests **from the `kafka-selfservice-gitops` repo** and let it
manage everything:

```bash
# In your clone of kafka-selfservice-gitops (edit the repoURLs in these files first):
kubectl apply -f argocd/platform-app.yaml     # reconciles the portal repo's platform/
kubectl apply -f argocd/tenants-appset.yaml   # one App per apps/* in the config repo
```

If you're not using Argo CD, apply directly instead: `kubectl apply -k platform/`
(portal repo) and `kubectl apply -k apps/<app>/kong/` (config repo).

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

Because the image runs with `NODE_ENV=production` and the app uses guest sign-in, make
sure `packages/app/src/App.tsx` renders a guest `SignInPage` so the app can get an
identity in production:

```tsx
import { SignInPage } from '@backstage/core-components';
// in createApp({ components: { ... } }):
SignInPage: props => <SignInPage {...props} auto providers={['guest']} />,
```

(The matching backend config — `auth.providers.guest.dangerouslyAllowOutsideDevelopment`
— is already in `platform/backstage/app-config.configmap.yaml`.)

### 3b. Build and push the image

`create-app` scaffolds `packages/backend/Dockerfile`. **Build the whole repo with
`yarn build:all`, not just `build:backend`** — otherwise the frontend isn't bundled and
you get a blank page (index.html/title load, but the JS bundle is missing):

```bash
yarn install --immutable
yarn tsc
yarn build:all      # builds BOTH the frontend app and the backend (frontend gets bundled)
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
  `BACKEND_SECRET` (`openssl rand -base64 32`). The stub is plaintext for the demo;
  for anything real, replace it with a Sealed Secret or External Secret —
  [`docs/secrets.md`](secrets.md) has worked manifests for both.
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
`web` HTTPS listener on `kong-keg` and `platform/backstage/httproute.yaml` (both applied
already by the steps above). TLS is terminated at the gateway with the wildcard cert —
required, because Backstage needs a secure context (the Web Crypto API). With
`minikube tunnel` running:

```bash
# backstage.127-0-0-1.sslip.io -> 127.0.0.1 -> Kong :443 (TLS) -> Backstage :7007
open https://backstage.127-0-0-1.sslip.io   # self-signed cert: accept the warning
```

Prefer no Gateway/TLS? Port-forward and set both `app.baseUrl` and `backend.baseUrl`
in the ConfigMap to `http://localhost:7007` — `localhost` also counts as a secure
context, so the Web Crypto API works without HTTPS:

```bash
kubectl -n backstage port-forward svc/backstage 7007:7007
```

Both self-service templates and both AsyncAPI APIs load automatically from the
catalog Location. If you'd rather register manually, use **Create → Register Existing
Component** in the UI and paste your fork's `catalog-info.yaml` URL.

### 3f. Troubleshooting a blank page (title only)

`index.html` loaded (so you see the tab title) but the app didn't render. Open the
browser dev tools and work through these in order:

1. **Console shows `globalThis.crypto.randomUUID is not a function` (or `crypto.subtle`
   is undefined).**
   - The page isn't a **secure context**. Browsers only expose the Web Crypto API over
     HTTPS or on `localhost`/`127.0.0.1`. Serving Backstage over plain `http://` on a
     hostname like `backstage.127-0-0-1.sslip.io` breaks it. Fix: use the HTTPS gateway
     route (`https://backstage.127-0-0-1.sslip.io`, the default here) or port-forward to
     `http://localhost:7007`. This is the most common cause once assets load.
2. **Network tab — are `static/*.js` requests 200 or 404?**
   - 404 → the frontend wasn't bundled into the image. Rebuild with `yarn build:all`
     (not just `yarn build:backend`) and redeploy.
3. **Console — auth / identity errors, or a redirect to a broken sign-in?**
   - The image runs `NODE_ENV=production`; the scaffolded **guest** sign-in is
     dev-only unless allowed. This repo's ConfigMap now sets
     `auth.providers.guest.dangerouslyAllowOutsideDevelopment: true`, and your
     `packages/app/src/App.tsx` must render a guest `SignInPage` (see 3a). Rebuild the
     image after adding the SignInPage.
4. **The URL you open must match `app.baseUrl`/`backend.baseUrl`.**
   - The config is set to `https://backstage.127-0-0-1.sslip.io`. If you instead
     port-forward and open `http://localhost:7007`, the app fetches config/assets from
     the wrong origin and renders blank. Either open the gateway URL (with
     `minikube tunnel`) or set both base URLs to `http://localhost:7007` and redeploy.
5. **Backend logs** — confirm both configs loaded and there are no startup errors:
   ```bash
   kubectl -n backstage logs deploy/backstage | head -50
   # expect: "Loaded config from app-config.yaml, app-config.production.yaml"
   ```

After a config-only change: `kubectl apply -k platform/backstage/ &&
kubectl -n backstage rollout restart deployment/backstage`. After an App.tsx or
frontend change you must rebuild and repush the image.

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
