# Módulo A: Docker local + GCP Cloud SQL + AWS RDS (PostgreSQL)

## Requisitos
- Docker Desktop iniciado (Compose v2).
- Dos instancias PostgreSQL existentes: una Cloud SQL y una RDS.
- Conectividad autorizada desde el equipo a ambas instancias en TCP 5432 (o puertos configurados).
- Usuarios con permisos de conexión y SELECT 1; no se modifican tablas cloud.

## Windows PowerShell
1. Descomprimir ZIP y abrir PowerShell dentro de `otel-python-observability`.
2. `Copy-Item .env.example .env`
3. `notepad .env` y completar GCP_DB_HOST, GCP_DB_USER, GCP_DB_PASSWORD, GCP_DB_DATABASE, AWS_DB_HOST, AWS_DB_USER, AWS_DB_PASSWORD, AWS_DB_DATABASE. No usar comillas ni subir .env a repositorios.
4. `docker compose config --quiet` (si falla, revisar .env y Compose).
5. `docker compose up --build -d`
6. `docker compose ps`
7. `curl.exe http://localhost:8000/health`
8. `curl.exe http://localhost:8001/health`
9. `curl.exe http://localhost:8002/health`
10. `curl.exe -i http://localhost:8002/data/health` (HTTP 200 cuando ambas BD responden; 503 si alguna falla).
11. En PowerShell: `$body = @{customer_id='cliente001';amount=25000;currency='COP'} | ConvertTo-Json` y `Invoke-RestMethod -Uri http://localhost:8000/orders -Method Post -ContentType 'application/json' -Body $body`
12. Abrir Jaeger http://localhost:16686 y Prometheus http://localhost:9090. Esperar 10-30 segundos para exportación de métricas.
13. `docker compose logs --tail=100 data-service` y `docker compose logs --tail=100 otel-collector` para diagnóstico.
14. `docker compose down` para detener. No usar `-v` si deseas conservar los datos de PostgreSQL local.

## Configuración cloud
**Cloud SQL**: para conexión directa, habilitar IP pública, agregar la IP pública de salida de tu equipo en redes autorizadas, habilitar SSL/TLS según configuración y usar la dirección IP pública de la instancia. Alternativa más segura: Cloud SQL Auth Proxy en el host y una configuración de red apropiada; este ZIP usa conexión TCP directa y no configura el proxy. Si la instancia solo tiene IP privada, necesitas VPN/ruta privada.

**RDS**: usar el endpoint DNS de RDS, puerto 5432, Security Group con entrada desde la IP pública de salida de tu equipo y reglas de red compatibles. La instancia debe ser alcanzable (por ejemplo, pública de forma controlada, o VPN/túnel para instancias privadas). Nunca abrir 5432 a 0.0.0.0/0.

`GCP_DB_SSL_MODE=require` y `AWS_DB_SSL_MODE=require` cifran la conexión, pero **no verifican identidad del servidor**. Para un entorno seguro, usar `verify-full` con CA de confianza y nombre DNS compatible; esto requiere configurar certificados y posiblemente el método de conexión a Cloud SQL.

## Arquitectura y pruebas
Orders y Payments usan PostgreSQL de Docker. Data usa Cloud SQL y RDS. `DATA_CHECK_ON_ORDER=true` hace que cada orden invoque Data, de modo que en Jaeger se vean las llamadas HTTP y spans SQL de ambas bases. Si alguna base está inaccesible, la creación de órdenes puede fallar (aunque Payments haya sido llamado); para aislar el problema, poner `DATA_CHECK_ON_ORDER=false` y ejecutar `/data/health` independientemente.

En Jaeger buscar `orders-service` y `data-service`. En Prometheus revisar el target `otel-collector` y las métricas `data_db_queries_total` (el nombre exacto puede variar con la traducción OTLP/Prometheus).

**Alcance**: Istio no se ejecuta en Docker Compose. La carpeta k8s es material de referencia para una fase posterior; no demuestra Service Mesh L7 en este despliegue.
