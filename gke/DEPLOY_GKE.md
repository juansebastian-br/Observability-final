# Despliegue en GKE Standard con Istio (laboratorio)

**Alcance:** tres servicios Python, PostgreSQL efímero para órdenes/pagos, dos conexiones PostgreSQL cloud desde `data-service`, OTel Collector, Jaeger, Prometheus, sidecars Envoy y métricas/trazas L7. No es configuración de producción. El clúster, IP pública y Artifact Registry pueden generar costes.

## Requisitos

- gcloud CLI, kubectl, Docker, `istioctl` (versión compatible con tu clúster) y permisos para GKE, Artifact Registry e IAM.
- GKE Standard con nodos Linux y capacidad para sidecars. Autopilot puede requerir ajustes adicionales.
- PostgreSQL Cloud SQL y RDS accesibles desde la red de los nodos de GKE (idealmente IP privada + VPN/peering/interconexión; alternativamente IP pública y egreso NAT con IP fija autorizada). **La IP pública de tu PC no es la IP de salida de GKE**.
- Cloud SQL: permitir la IP de salida del clúster si usas IP pública; RDS: security group inbound TCP 5432 solo desde egreso autorizado; configurar rutas, VPC y firewalls. SSL `require` cifra pero no valida identidad: para producción configurar `verify-full` y CA.

## 1. Variables (bash, Cloud Shell recomendado)

```bash
export PROJECT_ID='TU_PROJECT_ID'
export REGION='us-central1'
export CLUSTER='otel-lab'
export REPO='otel-lab'
export TAG='v1'
gcloud config set project "$PROJECT_ID"
gcloud services enable container.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com
# Omite el siguiente comando si ya tienes clúster:
gcloud container clusters create "$CLUSTER" --region "$REGION" --num-nodes=2 --machine-type=e2-standard-4
# O recupera credenciales del clúster existente:
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT_ID"
gcloud artifacts repositories create "$REPO" --repository-format=docker --location="$REGION" 2>/dev/null || true
gcloud auth configure-docker "$REGION-docker.pkg.dev"
```

## 2. Service mesh: Cloud Service Mesh gestionado (despliegue actual)

El clúster `otel-lab` (Autopilot, proyecto `crafty-dynamics-239114`) usa Cloud Service Mesh gestionado con implementación `TRAFFIC_DIRECTOR` (fleet `MANAGEMENT_AUTOMATIC`). En esa implementación:

- La API `Telemetry` solo admite `telemetry.istio.io/v1alpha1` y el subconjunto de trazas/access logs; el proveedor es `stackdriver` (Cloud Trace / Cloud Logging), no `otel-tracing`.
- Las métricas L7 HTTP de Envoy se publican solas en Cloud Monitoring (`istio.io/service/server/request_count`, `.../response_latencies`).
- La inyección de sidecars depende de la etiqueta `istio-injection=enabled` del namespace (`gke/namespace.yaml`). Si un `kubectl apply` del namespace la elimina, los pods nuevos quedan fuera del mesh.

```bash
gcloud container fleet mesh describe --project "$PROJECT_ID"   # REVISION_READY / ACTIVE
kubectl apply -f gke/namespace.yaml
```

`gke/istio-provider.yaml` solo sirve para Istio autogestionado (`istioctl install`); no aplica a Cloud Service Mesh gestionado.

## 2b. Workload Identity del collector

El collector exporta a Cloud Monitoring, Cloud Trace y Cloud Logging con la KSA `observability-lab/otel-collector` (creada en `gke/collector-config.yaml`):

```bash
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
M="principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/observability-lab/sa/otel-collector"
for r in roles/monitoring.metricWriter roles/cloudtrace.agent roles/logging.logWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$M" --role="$r" --condition=None
done
```

Ajusta `GCP_PROJECT_ID` en `gke/configmap.yaml` si cambias de proyecto.

## 3. Crear Secrets SIN subirlos al repositorio

`cloud-db-auth` almacena credenciales de ambos PostgreSQL; usa el nombre de host/IP alcanzable **desde GKE**. `app-db-url` es la base efímera interna de órdenes y pagos y **debe usar el mismo usuario, base y contraseña** que `local-postgres-auth` + `postgres-secret` (si no, orders/payments fallan con `fe_sendauth: no password supplied`). Evita guardar los secretos en historial o archivos compartidos: el siguiente ejemplo es didáctico, usa `read -s` en la terminal.

```bash
kubectl -n observability-lab create secret generic local-postgres-auth \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_DB=postgres
kubectl -n observability-lab create secret generic postgres-secret \
  --from-literal=POSTGRES_PASSWORD='CAMBIAR_PASSWORD_LOCAL'
kubectl -n observability-lab create secret generic app-db-url \
  --from-literal=DATABASE_URL='postgresql+psycopg://postgres:CAMBIAR_PASSWORD_LOCAL@postgres:5432/postgres'
# Sustituye los ocho valores con tus datos (sin compartir contraseñas):
kubectl -n observability-lab create secret generic cloud-db-auth \
  --from-literal=GCP_DB_HOST='IP_O_DNS_CLOUD_SQL' \
  --from-literal=GCP_DB_USER='USUARIO_GCP' \
  --from-literal=GCP_DB_PASSWORD='PASSWORD_GCP' \
  --from-literal=GCP_DB_DATABASE='postgres' \
  --from-literal=AWS_DB_HOST='ENDPOINT_RDS' \
  --from-literal=AWS_DB_USER='USUARIO_AWS' \
  --from-literal=AWS_DB_PASSWORD='PASSWORD_AWS' \
  --from-literal=AWS_DB_DATABASE='postgres'
```

Para contraseñas con `@`, `:`, `/` o `%`, codifica la contraseña en `DATABASE_URL` (URL encoding). Para un entorno real utiliza Secret Manager/External Secrets y Workload Identity.

## 4. Construir y publicar imágenes

Desde la raíz del proyecto:

```bash
for svc in orders payments data; do
  docker build -t "$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/$svc:$TAG" "services/$svc"
  docker push "$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/$svc:$TAG"
done
```

Si los nodos GKE no tienen permisos para descargar de Artifact Registry, asigna `roles/artifactregistry.reader` a la service account de los nodos (o configura `imagePullSecrets`).

## 5. Desplegar

```bash
kubectl apply -f gke/configmap.yaml
kubectl apply -f gke/postgres.yaml
kubectl apply -f gke/collector-config.yaml
kubectl apply -f gke/jaeger.yaml
kubectl apply -f gke/prometheus.yaml
kubectl apply -f gke/orders.yaml -f gke/payments.yaml -f gke/data.yaml
for svc in orders payments data; do
  kubectl -n observability-lab set image deployment/$svc-service "$svc-service=$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/$svc:$TAG"
done
kubectl apply -f gke/istio-telemetry.yaml
kubectl apply -f gke/istio-gateway.yaml
kubectl -n observability-lab rollout status deployment/postgres --timeout=180s
kubectl -n observability-lab rollout status deployment/otel-collector --timeout=180s
for svc in orders payments data; do kubectl -n observability-lab rollout status deployment/$svc-service --timeout=240s; done
kubectl -n observability-lab get pods
```

**Nota:** las plantillas `orders.yaml`, `payments.yaml`, `data.yaml` contienen imágenes marcadoras `REPLACE_IMAGE_*` y deben reemplazarse con `kubectl set image` como se muestra; en un despliegue automatizado, genera manifiestos con Kustomize/Helm para evitar un rollout fallido inicial. El `emptyDir` de PostgreSQL pierde los datos al recrear el pod; úsalo solo en el laboratorio.

## 6. Pruebas

En terminales separadas:

```bash
kubectl -n observability-lab port-forward svc/orders-service 8000:8000
kubectl -n observability-lab port-forward svc/data-service 8002:8002
kubectl -n observability-lab port-forward svc/jaeger 16686:16686
kubectl -n observability-lab port-forward svc/prometheus 9090:9090
```

En otra terminal:

```bash
curl -i http://localhost:8002/data/health
curl -i -X POST http://localhost:8000/orders -H 'Content-Type: application/json' \
  -d '{"customer_id":"demo","amount":25000,"currency":"COP"}'
```

Jaeger: http://localhost:16686 (trazas de aplicación y spans de proxy). Prometheus: http://localhost:9090. Consulta `istio_requests_total` y métricas `data_db_queries_total` (nombres pueden cambiar según normalización del exporter).

Verifica sidecars y trazas L7:

```bash
kubectl -n observability-lab get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}'
kubectl -n observability-lab logs deployment/data-service -c data-service --tail=80
kubectl -n observability-lab logs deployment/otel-collector --tail=80
kubectl -n observability-lab get telemetry
kubectl -n observability-lab get gateway,virtualservice
```

Para validar tráfico a través de Istio ingress, verifica el servicio `istio-ingressgateway` en `istio-system`, su IP pública y envía `POST /orders` a esa IP. No abras endpoints públicos sin controles de acceso en un entorno real.

## Limitaciones y seguridad

- La integración de Cloud SQL y RDS se realiza por TCP/TLS directo; no se incluye Cloud SQL Auth Proxy ni IAM DB Auth.
- Jaeger all-in-one, Prometheus sin PVC y PostgreSQL con `emptyDir` no conservan datos tras reinicios; solo laboratorio.
- El collector envía logs a su salida `debug` (consultables con `kubectl logs`); no se configura almacenamiento central persistente.
- El muestreo de trazas al 100% es para pruebas, no recomendado en producción.
- No se incluye política mTLS STRICT, autorización de red ni NetworkPolicy; Istio habilita sidecars y telemetría L7, no una postura de seguridad completa.
- Si no hay acceso desde GKE a las dos bases, `/data/health` devolverá 503 aunque los pods estén saludables.
