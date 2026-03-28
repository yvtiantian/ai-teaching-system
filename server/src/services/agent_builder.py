"""Agent 构建器

从 Supabase 读取 agent 配置，构建 Agno Agent + AgentOS。
"""

from agno.agent import Agent
from agno.models.deepseek import DeepSeek
from agno.db.sqlite.sqlite import SqliteDb
from agno.os.app import AgentOS
from agno.os.interfaces.agui import AGUI
from loguru import logger

from src.core.settings import settings
from src.services.session_service import get_db


def build_agent(config: dict) -> Agent:
    """根据配置字典构建一个 Agno Agent"""
    model_id = config.get("model_name") or settings.deepseek.resolved_chat_model
    model = DeepSeek(
        id=model_id,
        api_key=settings.deepseek.api_key,
        base_url=settings.deepseek.base_url,
    )

    db = get_db()

    agent = Agent(
        name=config.get("name", "Teaching Assistant"),
        id=config.get("id", "teaching-assistant"),
        model=model,
        instructions=config.get("instructions", "你是一个教学助手。"),
        db=db,
        add_history_to_context=True,
        num_history_runs=10,
        add_datetime_to_context=True,
        markdown=True,
    )

    return agent


def build_agent_os(agent: Agent) -> AgentOS:
    """将 Agent 包装为 AgentOS（含 AGUI 接口）"""
    agent_os = AgentOS(
        agents=[agent],
        db=get_db(),
        interfaces=[AGUI(agent=agent)],
        telemetry=False,
    )
    return agent_os
