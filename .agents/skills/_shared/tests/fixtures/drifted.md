# widget Platform

<!-- format drift: sections reordered, labels reworded, an unknown section added,
     extra prose between header and anchor line. Parser must still find values. -->

## Some New Section The Operator Added Later

This section did not exist when the parser was written. It must be ignored, not break parsing.

- Some Field: `whatever`

## Container Registry

The image registry for this project:

- Registry: `ghcr.io/dodo-ai-platform/widget`

## Observability

- OTLP HTTP endpoint: `alloy.infra-alloy.svc.cluster.local:4318`

## CI/CD

- Deploy secret: `KUBE_CONFIG_B64`

## Database

- Credentials secret: `widget-db-credentials`

## Namespace

- Name: `widget`
- ResourceQuota: CPU 1, Memory 2Gi

## Monitoring

- Dashboard: https://grafana.p.dodoteam.ru/d/widget
