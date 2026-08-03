# GitOps

This is the delivery mechanism that connects Backstage self-service to the cluster.

```
gitops/
├── argocd/
│   ├── platform-app.yaml      # Argo CD App for platform/ (bootstrap)
│   └── tenants-appset.yaml    # ApplicationSet: one App per gitops/apps/*
└── apps/
    └── <app>/                 # created by the Backstage PR, one dir per application
        ├── catalog-info.yaml
        └── kong/
            ├── virtual-cluster.yaml
            ├── acl-policy.yaml
            ├── tlsroute.yaml
            ├── scram-credentials.yaml
            └── kustomization.yaml
```

## Flow

1. A developer runs **Consume Kafka Topics** in Backstage.
2. The template opens a PR adding `gitops/apps/<app>/`.
3. On merge, the ApplicationSet detects the new directory and creates an Argo CD
   Application that applies `gitops/apps/<app>/kong/`.
4. Kong Operator reconciles those CRDs into the Konnect control plane and the Event
   Gateway data plane. The app can now connect.

Adding topics later is a PR that only changes `gitops/apps/<app>/kong/acl-policy.yaml`.

`gitops/apps/fraud-analytics/` is a worked example so you can see the end state
without running Backstage first.
