# Managing secrets for real

The repo ships plaintext `REPLACE_ME` stubs so the demo applies cleanly. In a real
deployment you never commit secret values to Git. GitOps still wants everything in
Git, so you commit either an *encrypted* secret (Sealed Secrets) or a *reference* to
a secret (External Secrets). Both produce, in-cluster, exactly the same Kubernetes
`Secret` objects the manifests already expect:

| Secret | Namespace | Keys | Consumed by |
|--------|-----------|------|-------------|
| `backstage-secrets` | `backstage` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `GITHUB_TOKEN`, `BACKEND_SECRET` | Backstage Deployment + Postgres |
| `konnect-api-auth-secret` | `kong` | `token` | Kong Operator → Konnect |

The name/namespace/keys must match what the manifests reference — only *how* the
values arrive changes. Delete the stub `backstage-secrets.yaml` from the kustomization
when you adopt one of these.

> The virtual cluster's SASL/PLAIN password is **not** a Kubernetes Secret — it lives
> in the `EventGatewayVirtualCluster` config (pushed to Konnect by the operator), so a
> K8s secret store wouldn't be read for it. For real use, replace the inline
> `password:` literal with a secret-template expression / Konnect vault reference
> rather than a Sealed/External Secret.

---

## Option A — Sealed Secrets (encrypt-and-commit)

Best when you want everything in Git and no external secret store. You encrypt a
Secret with the cluster controller's public key; only the in-cluster controller can
decrypt it, so the ciphertext is safe to commit.

**Install the controller once:**

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets -n kube-system sealed-secrets/sealed-secrets
# kubeseal CLI: https://github.com/bitnami/sealed-secrets/releases
```

**Seal the Backstage secret** (the plaintext Secret never touches Git — it's piped
straight into `kubeseal`):

```bash
kubectl create secret generic backstage-secrets \
  --namespace backstage \
  --from-literal=POSTGRES_USER=backstage \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=GITHUB_TOKEN="$GITHUB_TOKEN" \
  --from-literal=BACKEND_SECRET="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
> platform/backstage/backstage-sealedsecret.yaml
```

**The committed result** (`backstage-sealedsecret.yaml`) — values are RSA ciphertext:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: backstage-secrets
  namespace: backstage
spec:
  encryptedData:
    POSTGRES_USER: AgBy8x...           # ciphertext, safe to commit
    POSTGRES_PASSWORD: AgCf1q...
    GITHUB_TOKEN: AgD9k2...
    BACKEND_SECRET: AgETn7...
  template:
    metadata:
      name: backstage-secrets          # the plain Secret the controller creates
      namespace: backstage
    type: Opaque
```

The controller watches the `SealedSecret` and materializes a normal `Secret` named
`backstage-secrets`. Swap `backstage-secrets.yaml` for `backstage-sealedsecret.yaml`
in `platform/backstage/kustomization.yaml`.

> Default scoping is *strict*: a SealedSecret is bound to its name **and** namespace,
> so it can't be renamed or moved without re-sealing. Rotating a value = re-run the
> `kubeseal` pipeline and commit the new ciphertext.

Same pattern for the Konnect secret, just change name/namespace/keys —
e.g. `kubectl create secret generic konnect-api-auth-secret -n kong
--from-literal=token=... | kubeseal ...`.

---

## Option B — External Secrets Operator (reference an external store)

Best when a secrets manager is your source of truth (HashiCorp Vault, AWS Secrets
Manager, GCP Secret Manager, Azure Key Vault, …). Git holds only a *pointer*; ESO
fetches the values and creates/refreshes the Kubernetes Secret.

**Install ESO once:**

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system --create-namespace
```

**Define how to reach the store** (Vault example, using the Backstage ServiceAccount
for Kubernetes auth):

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: backstage
spec:
  provider:
    vault:
      server: https://vault.example.com:8200
      path: secret          # KV v2 mount
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: backstage
          serviceAccountRef:
            name: backstage
```

**Declare what to fetch** — ESO creates a Secret named `backstage-secrets` with the
four keys mapped from Vault paths:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: backstage-secrets
  namespace: backstage
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: backstage-secrets     # the K8s Secret that gets created
    creationPolicy: Owner
  data:
    - secretKey: POSTGRES_USER
      remoteRef: { key: backstage/db, property: username }
    - secretKey: POSTGRES_PASSWORD
      remoteRef: { key: backstage/db, property: password }
    - secretKey: GITHUB_TOKEN
      remoteRef: { key: backstage/github, property: token }
    - secretKey: BACKEND_SECRET
      remoteRef: { key: backstage/backend, property: secret }
```

Commit the `SecretStore` + `ExternalSecret` (no secret values in them) and drop the
stub `backstage-secrets.yaml` from the kustomization. For the Konnect secret, add an
analogous `ExternalSecret` in the `kong` namespace with a store that resolves in that
namespace (or a `ClusterSecretStore`), targeting `konnect-api-auth-secret`.

> Rotation is automatic: change the value in the store and ESO refreshes the Secret
> on the next `refreshInterval`. Restarting the consuming pod may still be needed for
> env-var-mounted secrets like these.

---

## Which one?

- **Sealed Secrets** — simplest, fully self-contained in Git, no external system. You
  manage rotation manually by re-sealing.
- **External Secrets** — best when you already run a secrets manager and want central
  rotation, auditing and shared ownership. More moving parts.

Either way the platform manifests are unchanged — they just consume the resulting
`Secret` objects.
