# nodb Platform

## Namespace

- Name: `nodb`
- ResourceQuota: CPU 4, Memory 8Gi

## Object Storage

- Credentials secret: `nodb-bucket-credentials`
- Bucket: `p-aipltf-nodb-bucket`

## Container Registry

- Registry: `ghcr.io/dodo-ai-platform/nodb`

## Observability

- OTLP HTTP endpoint: `alloy.infra-alloy.svc.cluster.local:4318`

## CI/CD

- Deploy secret: `KUBE_CONFIG_B64` (base64-encoded kubeconfig for deployer SA)
