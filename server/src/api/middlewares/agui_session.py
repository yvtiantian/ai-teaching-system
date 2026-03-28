"""AGUI session middleware.

在 AGUI 对话请求进入 AgentOS 前自动确保 session 存在：
- 首次 thread 自动创建 session
- 标题取用户第一条消息
- 保持请求体可重放，避免破坏 StreamingResponse
"""

import json
from collections.abc import Awaitable, Callable
from typing import Any

from loguru import logger
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

from src.core.security import decode_jwt_token
from src.core.settings import settings
from src.services.session_service import SessionNotFoundError, SessionService


class AGUISessionMiddleware(BaseHTTPMiddleware):
    """Ensure AGUI thread has a persisted session before agent streaming starts."""

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        if not self._is_agui_request(request):
            return await call_next(request)

        body_bytes = await request.body()
        try:
            data = json.loads(body_bytes)
        except Exception:
            return await self._continue_with_body(request, body_bytes, call_next)

        thread_id = data.get("threadId") or data.get("thread_id")
        agent_id = self._extract_agent_id(request)
        user_id = self._extract_user_id(request, data)
        raw_messages = data.get("messages")
        messages = raw_messages if isinstance(raw_messages, list) else []

        if thread_id and agent_id and user_id:
            try:
                await self._ensure_session_exists(
                    thread_id=thread_id,
                    agent_id=agent_id,
                    user_id=user_id,
                    messages=messages,
                )
            except Exception as exc:
                logger.error("AGUI 自动创建会话失败: {}", exc)

        response = await self._continue_with_body(request, body_bytes, call_next)
        if response.status_code == 422:
            logger.warning("AGUI request validation failed (422): {}", request.url.path)
        return response

    def _is_agui_request(self, request: Request) -> bool:
        return request.method == "POST" and request.url.path.startswith(
            "/agents/"
        ) and request.url.path.endswith("/agui")

    async def _continue_with_body(
        self,
        request: Request,
        body_bytes: bytes,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        # Re-inject the consumed request body exactly once, then fall back to the
        # original ASGI receive channel so StreamingResponse can observe disconnects.
        original_receive = request.receive
        body_sent = False

        async def receive() -> dict[str, Any]:
            nonlocal body_sent
            if not body_sent:
                body_sent = True
                return {"type": "http.request", "body": body_bytes, "more_body": False}
            return await original_receive()

        replay_request = Request(scope=request.scope, receive=receive)
        return await call_next(replay_request)

    def _extract_agent_id(self, request: Request) -> str | None:
        path_parts = request.url.path.split("/")
        try:
            idx = path_parts.index("agents")
            if idx + 1 < len(path_parts):
                return path_parts[idx + 1]
        except (ValueError, IndexError):
            return None
        return None

    def _extract_user_id(self, request: Request, data: dict) -> str:
        # 优先使用鉴权中间件注入的用户 claims
        user_claims = getattr(request.state, "user", None)
        if isinstance(user_claims, dict):
            user_id = user_claims.get("sub") or user_claims.get("user_id")
            if user_id:
                return str(user_id)

        if hasattr(request.state, "user_id"):
            user_id = getattr(request.state, "user_id")
            if user_id:
                return str(user_id)

        # /agents/* 路径当前可匿名访问，兼容从 forwardedProps 透传用户信息
        forwarded_props = data.get("forwardedProps") or data.get("forwarded_props", {})
        if isinstance(forwarded_props, dict):
            user_id = (
                forwarded_props.get("user_id")
                or forwarded_props.get("userId")
                or forwarded_props.get("sub")
            )
            if user_id:
                return str(user_id)

        # 最后尝试用 JWT 解码补齐用户上下文（即使该路径被标记为 public）
        auth_header = request.headers.get("Authorization", "")
        if auth_header.startswith("Bearer ") and settings.supabase.jwt_secret:
            token = auth_header[7:]
            try:
                payload = decode_jwt_token(token, settings.supabase.jwt_secret)
                user_id = payload.get("sub") or payload.get("user_id")
                if user_id:
                    return str(user_id)
            except Exception:
                logger.debug("AGUI middleware failed to decode JWT for user context")

        return "anonymous"

    async def _ensure_session_exists(
        self,
        thread_id: str,
        agent_id: str,
        user_id: str,
        messages: list[dict],
    ) -> None:
        service = SessionService(user_id=user_id)

        try:
            service.get_session(thread_id)
            return
        except SessionNotFoundError:
            pass

        # 用用户第一条消息作为会话标题
        title = _extract_first_user_message(messages)

        await service.create_session(
            session_id=thread_id,
            agent_id=agent_id,
            messages=messages,
            auto_generate_title=False,
            initial_title=title,
        )

        logger.info(
            "AGUI 自动创建会话: thread_id={}, user_id={}, agent_id={}",
            thread_id,
            user_id,
            agent_id,
        )


def _extract_first_user_message(messages: list[dict]) -> str:
    """从消息列表中提取第一条用户消息作为标题。"""
    for msg in messages:
        role = msg.get("role", "")
        content = msg.get("content", "")
        if role == "user" and content and isinstance(content, str):
            # 取第一行，截断到 30 字符
            first_line = content.strip().split("\n")[0].strip()
            if first_line:
                return first_line[:30]
    return "新会话"
