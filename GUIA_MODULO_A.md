# Módulo A: ejecución

## Requisitos
Docker Desktop + Docker Compose v2.24+, instancias PostgreSQL activas en Cloud SQL y RDS, red accesible desde Docker y credenciales SQL con permisos mínimos. En producción preferir Cloud SQL Auth Proxy / conectividad privada para GCP y TLS verificado + IAM/Secrets Manager para AWS.

## Pasos

```bash
cp .env.example .env
# Editar .env con los dos endpoints y credenciales (no subir a Git).
docker compose config
docker compose up --build -d
docker compose ps
curl http://localhost:8000/health
curl http://localhost:8001/health
curl http://localhost:8002/health
curl -i http://localhost:8002/data/health
curl -X POST http://localhost:8000/orders -H 'Content-Type: application/json' -d '{"customer_id":"demo","amount":25000,"currency":"COP"}'
```

Jaeger http://localhost:16686; Prometheus http://localhost:9090. Buscar trazas de `data-service` y spans `data.db.healthcheck` y SQLAlchemy. Consultar métricas `data_db_queries_total` (puede variar según traducción OTLP/Prometheus). Ver logs con `docker compose logs -f data-service otel-collector`.

Para integrar data-service en la transacción distribuida, cambiar `DATA_CHECK_ON_ORDER=true` en `.env` y reiniciar `docker compose up -d --force-recreate orders-service`. Esto agrega una verificación de conectividad en cada orden y **no** debe tratarse como diseño transaccional de producción.

## Conectividad
Cloud SQL PostgreSQL: habilitar IP pública con lista de IPs autorizadas **solo para laboratorio**, o usar Cloud SQL Auth Proxy y conectividad segura. RDS PostgreSQL: Security Group de entrada 5432 desde la IP pública del host o red privada/VPN, no `0.0.0.0/0`. Asegurar que ambos usuarios puedan ejecutar `SELECT 1`. `sslmode=require` cifra pero no verifica identidad del servidor: para producción configurar certificados CA y `verify-full`.

## Limitaciones
No se incluyen recursos cloud ni credenciales. El mesh requiere Kubernetes + Istio: ver `k8s/README.md`. La configuración de CloudWatch existente no se activa en el compose local; los logs se ven en Docker/Collector. Para despliegues reales ajustar TLS OTLP, RBAC, certificados, secretos y retención.
