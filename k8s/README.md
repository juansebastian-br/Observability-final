# Istio en GKE: guía de integración

1. Crear un clúster GKE Standard compatible y conectarse con `gcloud container clusters get-credentials ...`.
2. Instalar Istio con `istioctl install --set profile=demo -y` (solo laboratorio).
3. Instalar un Collector accesible desde el clúster y configurar un proveedor de trazas `otel-tracing` en Istio MeshConfig, apuntando al servicio OTLP gRPC del Collector (el recurso Telemetry por sí solo no crea el proveedor).
4. `kubectl apply -f k8s/istio-observability.yaml`.
5. Publicar las tres imágenes en Artifact Registry y desplegar Deployments y Services de orders, payments y data en `observability-lab`, con `OTEL_EXPORTER_OTLP_ENDPOINT` apuntando al Collector dentro del clúster. Montar credenciales de BD como Kubernetes Secrets, nunca en manifiestos versionados.
6. `kubectl -n observability-lab get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}'` debe mostrar el contenedor `istio-proxy` en cada pod.
7. Verificar métricas L7 de Envoy (`istio_requests_total`, duración, códigos HTTP) desde Prometheus configurado para hacer scrape de los sidecars. Generar tráfico y comprobar trazas en Jaeger.

Nota: este directorio configura la política de Telemetry, pero **no es un despliegue Kubernetes completo**. Es necesario adaptar imágenes, secretos, servicios, collector, proveedor de trazas y scrape a tu clúster. No habilitar muestreo al 100% en producción.
