# Project Name

AI Platform project. See `PLATFORM.md` for infrastructure details, credentials, and kubeconfig.

## Quick Start

1. Replace `myapp` in `k8s/deployment.yaml`, `k8s/service.yaml` with your app name
2. Update `Dockerfile` for your language/runtime
3. Update image reference in `k8s/deployment.yaml`: `ghcr.io/dodo-ai-platform/<repo-name>:IMAGE_TAG`
4. Uncomment `envFrom` in deployment if you use database, mongodb, or bucket
5. Push to `main` — CI builds, pushes to GHCR, and deploys automatically

## Local Development

```bash
# Port-forward to your service
kubectl port-forward svc/myapp -n <project-name> 8080:8080

# Check logs
kubectl logs deploy/myapp -n <project-name>

# Check events
kubectl get events -n <project-name> --sort-by='.lastTimestamp'
```
