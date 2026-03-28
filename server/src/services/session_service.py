"""Session 服务层

使用 agno SqliteDb 存储对话历史，对外提供 session CRUD。
对齐 imitate_server 的实现模式。
"""

from uuid import uuid4
import time

from agno.db.sqlite.sqlite import SqliteDb
from agno.db.base import SessionType
from agno.session.agent import AgentSession
from agno.session.summary import SessionSummary
from loguru import logger

from src.core.settings import settings
from src.services.title_generator import generate_title

_db: SqliteDb | None = None


def _get_db() -> SqliteDb:
    global _db
    if _db is None:
        _db = SqliteDb(db_file=settings.database.path)
    return _db


def get_db() -> SqliteDb:
    """获取全局 SqliteDb 实例（供 agent_builder 复用）"""
    return _get_db()


class SessionNotFoundError(Exception):
    pass


class SessionService:
    def __init__(self, user_id: str):
        self.user_id = user_id
        self.db = _get_db()

    def _get_user_sessions(self) -> list[AgentSession]:
        """获取当前用户的所有 agent sessions"""
        sessions = self.db.get_sessions(
            session_type=SessionType.AGENT,
            user_id=self.user_id,
        )
        if sessions is None:
            return []
        # get_sessions 可能返回 list 或 tuple(list, count)
        if isinstance(sessions, tuple):
            sessions = sessions[0]
        return [s for s in sessions if isinstance(s, AgentSession)]

    def list_sessions(
        self,
        page: int = 1,
        limit: int = 20,
        agent_id: str | None = None,
    ) -> tuple[list[dict], int]:
        """获取用户的 session 列表（分页）"""
        raw_sessions = self._get_user_sessions()

        # 按 agent_id 过滤
        if agent_id:
            raw_sessions = [s for s in raw_sessions if s.agent_id == agent_id]

        total = len(raw_sessions)

        # 转为 dict 列表
        sessions = [self._session_to_dict(s) for s in raw_sessions]

        # 按 updated_at 倒序
        sessions.sort(key=lambda s: s["updated_at"], reverse=True)

        # 分页
        start = (page - 1) * limit
        return sessions[start : start + limit], total

    def get_session(self, session_id: str) -> dict:
        """获取 session 详情（含消息）"""
        session = self._find_user_session(session_id)
        return self._session_to_dict(session, include_details=True)

    def _find_user_session(self, session_id: str) -> AgentSession:
        for s in self._get_user_sessions():
            if s.session_id == session_id:
                return s
        raise SessionNotFoundError(f"Session {session_id} not found")

    async def create_session(
        self,
        session_id: str | None = None,
        agent_id: str | None = None,
        messages: list[dict] | None = None,
        auto_generate_title: bool = True,
        initial_title: str | None = None,
    ) -> dict:
        """创建新 session"""
        session_id = session_id or str(uuid4())
        current_timestamp = int(time.time())

        title = initial_title or "新会话"
        if not initial_title and auto_generate_title and messages:
            title = await generate_title(messages)

        new_session = AgentSession(
            session_id=session_id,
            agent_id=agent_id,
            user_id=self.user_id,
            session_data={"messages": messages or []},
            summary=SessionSummary(summary=title),
            created_at=current_timestamp,
            updated_at=current_timestamp,
        )

        self.db.upsert_session(session=new_session)
        logger.info(f"Session 已创建: {session_id}, 标题: {title}")

        return self._session_to_dict(new_session)

    def update_session_title(self, session_id: str, title: str) -> dict:
        """更新 session 标题并刷新 updated_at。"""
        session = self._find_user_session(session_id)
        normalized_title = (title or "").strip() or "新会话"

        session.summary = SessionSummary(summary=normalized_title)
        session.updated_at = int(time.time())

        self.db.upsert_session(session=session)
        logger.info(f"Session 标题已更新: {session_id}, 标题: {normalized_title}")
        return self._session_to_dict(session)

    async def generate_and_update_session_title(
        self,
        session_id: str,
        messages: list[dict] | None,
    ) -> None:
        """异步生成并回填会话标题，不阻塞主对话链路。"""
        if not messages:
            return

        title = await generate_title(messages)
        try:
            self.update_session_title(session_id, title)
        except SessionNotFoundError:
            logger.warning(f"标题回填失败，session 不存在: {session_id}")

    def delete_session(self, session_id: str) -> None:
        """删除 session（先校验权限，再删除）"""
        # 确认 session 属于当前用户
        if not any(s.session_id == session_id for s in self._get_user_sessions()):
            raise SessionNotFoundError(f"Session {session_id} not found")
        self.db.delete_session(session_id=session_id)
        logger.info(f"Session 已删除: {session_id}")

    def _session_to_dict(
        self,
        session: AgentSession,
        include_details: bool = False,
    ) -> dict:
        """将 AgentSession 转为前端可消费的 dict"""
        session_name = session.summary.summary if session.summary else "新会话"

        result = {
            "session_id": session.session_id,
            "agent_id": str(session.agent_id) if session.agent_id else None,
            "title": session_name or "新会话",
            "created_at": str(session.created_at),
            "updated_at": str(session.updated_at),
        }

        if include_details:
            messages = self._extract_messages_from_runs(session.runs)
            result["messages"] = messages

        return result

    def _extract_messages_from_runs(self, runs: list | None) -> list[dict]:
        """从 agno runs 中提取对话消息

        Input (agno):  [{messages: [{id, role, content, ...}], ...}, ...]
        Output (frontend): [{id, role, content, created_at}, ...]
        """
        if not runs:
            return []

        messages: list[dict] = []
        for run in runs:
            run_messages = (
                run.messages if hasattr(run, "messages") else run.get("messages", [])
            )
            for msg in run_messages:
                msg_role = msg.role if hasattr(msg, "role") else msg.get("role")
                if msg_role == "system":
                    continue

                from_history = (
                    msg.from_history
                    if hasattr(msg, "from_history")
                    else msg.get("from_history", False)
                )
                if from_history:
                    continue

                msg_id = msg.id if hasattr(msg, "id") else msg.get("id")
                msg_content = (
                    msg.content if hasattr(msg, "content") else msg.get("content")
                )
                msg_created_at = (
                    msg.created_at
                    if hasattr(msg, "created_at")
                    else msg.get("created_at")
                )

                extracted = {
                    "id": str(msg_id) if msg_id else "",
                    "role": msg_role,
                    "content": msg_content,
                    "created_at": str(msg_created_at) if msg_created_at else "",
                }

                messages.append(extracted)

        return messages
