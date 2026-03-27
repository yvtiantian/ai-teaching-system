"""BDD 测试共享 fixtures"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

import pytest
from fastapi.testclient import TestClient


# ── 假的 Supabase 存储 ──────────────────────────────────────


class _FakeStorageBucket:
    """模拟 supabase.storage.from_(bucket).download(path) 返回文件字节。"""

    def __init__(self, files: dict[str, bytes]) -> None:
        self._files = files

    def download(self, path: str) -> bytes:
        key = path
        if key in self._files:
            return self._files[key]
        raise Exception(f"File not found: {path}")


class _FakeStorage:
    def __init__(self, files: dict[str, bytes]) -> None:
        self._files = files

    def from_(self, bucket: str) -> _FakeStorageBucket:
        return _FakeStorageBucket(self._files)


class _FakeTableQuery:
    """模拟 supabase.table().select().eq().maybe_single().execute() 链式调用。"""

    def __init__(self, data: dict[str, Any] | None = None) -> None:
        self._data = data

    def select(self, *_args: Any, **_kwargs: Any) -> "_FakeTableQuery":
        return self

    def eq(self, _col: str, _val: Any) -> "_FakeTableQuery":
        return self

    def maybe_single(self) -> "_FakeTableQuery":
        return self

    def execute(self) -> Any:
        @dataclass
        class _Result:
            data: dict[str, Any] | None
        return _Result(data=self._data)


class _FakeSupabaseClient:
    """最小化的 Supabase 客户端模拟。"""

    def __init__(
        self,
        files: dict[str, bytes] | None = None,
        course_owner: bool = True,
    ) -> None:
        self.storage = _FakeStorage(files or {})
        self._course_owner = course_owner

    def table(self, _name: str) -> _FakeTableQuery:
        if self._course_owner:
            return _FakeTableQuery(data={"id": "course-1"})
        return _FakeTableQuery(data=None)


# ── 假的 Ollama 响应 ──────────────────────────────────────


def build_mock_ollama_response(question_config: dict[str, Any]) -> dict:
    """根据题目配置生成符合格式的假 AI 响应。"""
    questions: list[dict] = []

    for qtype, cfg in question_config.items():
        count = cfg.get("count", 0)
        for i in range(count):
            q: dict[str, Any] = {
                "question_type": qtype,
                "content": f"测试{qtype}题目_{i + 1}",
                "explanation": f"这是{qtype}的解析",
            }

            if qtype == "single_choice":
                q["options"] = [
                    {"label": "A", "text": "选项A"},
                    {"label": "B", "text": "选项B"},
                    {"label": "C", "text": "选项C"},
                    {"label": "D", "text": "选项D"},
                ]
                q["correct_answer"] = {"answer": "B"}
            elif qtype == "multiple_choice":
                q["options"] = [
                    {"label": "A", "text": "选项A"},
                    {"label": "B", "text": "选项B"},
                    {"label": "C", "text": "选项C"},
                    {"label": "D", "text": "选项D"},
                ]
                q["correct_answer"] = {"answer": ["A", "C"]}
            elif qtype == "true_false":
                q["options"] = None
                q["correct_answer"] = {"answer": False}
            elif qtype == "fill_blank":
                q["options"] = None
                q["correct_answer"] = {"answer": ["答案"]}
            elif qtype == "short_answer":
                q["options"] = None
                q["correct_answer"] = {"answer": "这是参考答案"}

            questions.append(q)

    return {"questions": questions}


# ── BDD 上下文 ──────────────────────────────────────────────


@dataclass
class BDDContext:
    """在 BDD steps 之间传递状态的容器。"""

    # 认证信息
    user_id: str = "teacher-uid-001"
    course_id: str = "course-001"
    is_course_owner: bool = True

    # 文件
    uploaded_files: dict[str, bytes] = field(default_factory=dict)
    file_paths: list[str] = field(default_factory=list)

    # 题目配置
    question_config: dict[str, dict[str, Any]] = field(default_factory=dict)
    ai_prompt: str | None = None

    # 结果
    response: Any = None
    error: Exception | None = None
    result: dict[str, Any] | None = None


@pytest.fixture
def ctx() -> BDDContext:
    return BDDContext()


@pytest.fixture
def fake_supabase(ctx: BDDContext) -> _FakeSupabaseClient:
    return _FakeSupabaseClient(
        files=ctx.uploaded_files,
        course_owner=ctx.is_course_owner,
    )
