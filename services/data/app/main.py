import os
import time
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL
from opentelemetry.trace import Status, StatusCode
from .otel import configure_otel, shutdown_otel


def db_engine(prefix):
    # Individual components avoid URL-encoding errors with special characters in passwords.
    host = os.getenv(f"{prefix}_HOST", "").strip()
    if not host:
        return None
    args = {}
    if os.getenv(f"{prefix}_SSL_MODE", "require"):
        args["sslmode"] = os.getenv(f"{prefix}_SSL_MODE", "require")
    url = URL.create("postgresql+psycopg", username=os.environ[f"{prefix}_USER"],
                     password=os.environ[f"{prefix}_PASSWORD"], host=host,
                     port=int(os.getenv(f"{prefix}_PORT", "5432")),
                     database=os.environ[f"{prefix}_DATABASE"])
    return create_engine(url, pool_pre_ping=True, pool_size=2, max_overflow=2,
                         pool_timeout=5, connect_args={**args, "connect_timeout": 5})

engines = {name: db_engine(prefix) for name, prefix in (("gcp", "GCP_DB"), ("aws", "AWS_DB"))}
engines = {k: v for k, v in engines.items() if v is not None}

@asynccontextmanager
async def lifespan(app):
    yield
    for engine in engines.values():
        engine.dispose()
    shutdown_otel()

app = FastAPI(title="Data Service", version="1.0.0", lifespan=lifespan)
tracer, meter, logger = configure_otel(app, list(engines.values()))
queries = meter.create_counter("data.db.queries", unit="1", description="Database query attempts")
duration = meter.create_histogram("data.db.query.duration", unit="ms")

@app.get("/health")
def health():
    return {"status": "UP", "service": "data-service", "configured_databases": list(engines)}

@app.get("/data/health")
def databases_health():
    result = {}
    for name, engine in engines.items():
        started = time.perf_counter()
        outcome = "ok"
        with tracer.start_as_current_span("data.db.healthcheck") as span:
            span.set_attribute("db.system.name", "postgresql")
            span.set_attribute("db.operation.name", "SELECT")
            span.set_attribute("db.namespace", engine.url.database)
            span.set_attribute("server.address", engine.url.host or "")
            span.set_attribute("server.port", engine.url.port or 5432)
            span.set_attribute("cloud.provider", "gcp" if name == "gcp" else "aws")
            try:
                with engine.connect() as connection:
                    connection.execute(text("SELECT 1")).scalar_one()
                result[name] = {"status": "UP"}
                logger.info("database healthcheck succeeded", extra={"database": name})
            except Exception as exc:
                outcome = "error"
                result[name] = {"status": "DOWN", "error_type": type(exc).__name__}
                span.record_exception(exc)
                span.set_status(Status(StatusCode.ERROR))
                logger.exception("database healthcheck failed: %s", name)
            finally:
                attrs = {"database": name, "status": outcome}
                queries.add(1, attrs)
                duration.record((time.perf_counter()-started)*1000, attrs)
    if set(engines) != {"gcp", "aws"}:
        raise HTTPException(status_code=503, detail={"error": "Both GCP and AWS connections must be configured", "configured": list(engines)})
    if any(v["status"] == "DOWN" for v in result.values()):
        raise HTTPException(status_code=503, detail=result)
    return result
