import uuid

import jwt
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from src.api.middlewares.agui_session import AGUISessionMiddleware
from src.core.settings import settings
from src.middleware.auth import AuthMiddleware
from src.services.session_service import SessionNotFoundError


class _FakeSessionService:
    created_calls: list[dict] = []
    title_update_calls: list[dict] = []
    existing_session_ids: set[str] = set()
    init_user_ids: list[str] = []

    def __init__(self, user_id: str):
        self.user_id = user_id
        self.__class__.init_user_ids.append(user_id)

    def get_session(self, session_id: str) -> dict:
        if session_id in self.__class__.existing_session_ids:
            return {"session_id": session_id}
        raise SessionNotFoundError(session_id)

    async def create_session(
        self,
        session_id: str | None = None,
        agent_id: str | None = None,
        messages: list[dict] | None = None,
        auto_generate_title: bool = True,
        initial_title: str | None = None,
    ) -> dict:
        assert session_id is not None
        self.__class__.created_calls.append(
            {
                "user_id": self.user_id,
                "session_id": session_id,
                "agent_id": agent_id,
                "messages": messages or [],
                "auto_generate_title": auto_generate_title,
                "initial_title": initial_title,
            }
        )
        self.__class__.existing_session_ids.add(session_id)
        return {
            "session_id": session_id,
            "agent_id": agent_id,
            "title": "测试标题",
        }

    async def generate_and_update_session_title(
        self,
        session_id: str,
        messages: list[dict] | None,
    ) -> None:
        self.__class__.title_update_calls.append(
            {
                "user_id": self.user_id,
                "session_id": session_id,
                "message_count": len(messages or []),
            }
        )

    @classmethod
    def reset(cls) -> None:
        cls.created_calls = []
        cls.title_update_calls = []
        cls.existing_session_ids = set()
        cls.init_user_ids = []


def _build_test_app() -> FastAPI:
    app = FastAPI()
    app.add_middleware(AGUISessionMiddleware)

    @app.post("/agents/{agent_id}/agui")
    async def agui_handler(agent_id: str, request: Request) -> JSONResponse:
        payload = await request.json()
        return JSONResponse(
            {
                "agent_id": agent_id,
                "thread_id": payload.get("threadId"),
                "message_count": len(payload.get("messages", [])),
            }
        )

    return app


def _build_test_app_with_auth() -> FastAPI:
    app = FastAPI()
    app.add_middleware(AGUISessionMiddleware)
    app.add_middleware(AuthMiddleware)

    @app.post("/agents/{agent_id}/agui")
    async def agui_handler(agent_id: str, request: Request) -> JSONResponse:
        payload = await request.json()
        return JSONResponse(
            {
                "agent_id": agent_id,
                "thread_id": payload.get("threadId"),
                "message_count": len(payload.get("messages", [])),
            }
        )

    return app


def _build_payload(thread_id: str, forwarded_props: dict | None = None) -> dict:
    return {
        "threadId": thread_id,
        "runId": str(uuid.uuid4()),
        "parentRunId": None,
        "state": {},
        "messages": [
            {
                "role": "user",
                "id": str(uuid.uuid4()),
                "content": "你好，帮我解释二次方程",
            }
        ],
        "tools": [],
        "context": [],
        "forwardedProps": forwarded_props or {},
    }


def test_agui_auto_creates_session_on_first_message(monkeypatch) -> None:
    _FakeSessionService.reset()
    monkeypatch.setattr(
        "src.api.middlewares.agui_session.SessionService", _FakeSessionService
    )

    thread_id = str(uuid.uuid4())
    payload = _build_payload(thread_id, forwarded_props={"user_id": "student-1"})

    with TestClient(_build_test_app()) as client:
        resp = client.post("/agents/math/agui", json=payload)

    assert resp.status_code == 200
    assert resp.json()["thread_id"] == thread_id
    assert len(_FakeSessionService.created_calls) == 1

    created = _FakeSessionService.created_calls[0]
    assert created["user_id"] == "student-1"
    assert created["session_id"] == thread_id
    assert created["agent_id"] == "math"
    assert created["auto_generate_title"] is False
    assert created["messages"][0]["role"] == "user"


def test_agui_skips_creation_when_session_already_exists(monkeypatch) -> None:
    _FakeSessionService.reset()
    monkeypatch.setattr(
        "src.api.middlewares.agui_session.SessionService", _FakeSessionService
    )

    thread_id = str(uuid.uuid4())
    _FakeSessionService.existing_session_ids.add(thread_id)
    payload = _build_payload(thread_id, forwarded_props={"user_id": "student-2"})

    with TestClient(_build_test_app()) as client:
        resp = client.post("/agents/math/agui", json=payload)

    assert resp.status_code == 200
    assert resp.json()["thread_id"] == thread_id
    assert _FakeSessionService.created_calls == []


def test_agui_resolves_user_id_from_jwt_when_forwarded_props_missing(
    monkeypatch,
) -> None:
    _FakeSessionService.reset()
    monkeypatch.setattr(
        "src.api.middlewares.agui_session.SessionService", _FakeSessionService
    )

    original_secret = settings.supabase.jwt_secret
    settings.supabase.jwt_secret = "unit-test-secret-32-bytes-long-key"

    token = jwt.encode(
        {"sub": "jwt-user-7", "aud": "authenticated", "role": "authenticated"},
        settings.supabase.jwt_secret,
        algorithm="HS256",
    )

    thread_id = str(uuid.uuid4())
    payload = _build_payload(thread_id)

    try:
        with TestClient(_build_test_app()) as client:
            resp = client.post(
                "/agents/math/agui",
                json=payload,
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 200
        assert _FakeSessionService.init_user_ids[0] == "jwt-user-7"
    finally:
        settings.supabase.jwt_secret = original_secret


def test_agui_prefers_user_context_from_auth_middleware(monkeypatch) -> None:
    _FakeSessionService.reset()
    monkeypatch.setattr(
        "src.api.middlewares.agui_session.SessionService", _FakeSessionService
    )

    original_secret = settings.supabase.jwt_secret
    settings.supabase.jwt_secret = "unit-test-secret-32-bytes-long-key"
    token = jwt.encode(
        {"sub": "auth-user-11", "aud": "authenticated", "role": "authenticated"},
        settings.supabase.jwt_secret,
        algorithm="HS256",
    )

    thread_id = str(uuid.uuid4())
    payload = _build_payload(thread_id)

    try:
        with TestClient(_build_test_app_with_auth()) as client:
            resp = client.post(
                "/agents/math/agui",
                json=payload,
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert _FakeSessionService.init_user_ids[0] == "auth-user-11"
    finally:
        settings.supabase.jwt_secret = original_secret
