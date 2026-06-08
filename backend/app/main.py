from fastapi import FastAPI
import structlog

log = structlog.get_logger()

app = FastAPI(
    title="Professional Chef Agent API",
    version="1.0.0",
)

@app.on_event("startup")
async def startup():
    log.info("chef_agent_starting", environment="development")

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "service": "chef-agent-backend",
        "version": "1.0.0"
    }
