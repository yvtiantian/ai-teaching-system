from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from loguru import logger

from src.api.health import router as health_router
from src.api.agents import router as agents_router
from src.api.sessions import router as sessions_router
from src.api.assignments import router as assignments_router
from src.api.middlewares.agui_session import AGUISessionMiddleware
from src.middleware.auth import AuthMiddleware
from src.services.agent_manager import get_agent_manager
from src.core.settings import settings


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("AI Teaching System starting up...")

    # 确保 SQLite 数据目录存在
    db_dir = Path(settings.database.path).parent
    db_dir.mkdir(parents=True, exist_ok=True)

    # 从 Supabase 加载 agent 配置并挂载到 FastAPI
    manager = get_agent_manager()
    await manager.initialize(app)

    yield
    logger.info("AI Teaching System shutting down...")


app = FastAPI(
    title="AI Agent Teaching System",
    version="0.1.0",
    redirect_slashes=False,
    lifespan=lifespan,
)

app.add_middleware(AGUISessionMiddleware)
app.add_middleware(AuthMiddleware)

# CORS must be outermost so browser can read error responses from inner middlewares.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost",
        "http://127.0.0.1",
    ],
    allow_origin_regex=r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# API 路由
app.include_router(health_router)
app.include_router(agents_router)
app.include_router(sessions_router)
app.include_router(assignments_router)
