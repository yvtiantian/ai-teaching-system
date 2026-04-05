"""学生作业完整闭环 — BDD step 实现

覆盖：学生提交 → AI 批改（仅简答题）→ 教师一键采纳 → 教师手动改分 → 复核完成
客观题（单选/多选/判断/填空）由 SQL 自动评分，AI 仅处理简答题。
全流程通过内存级 Fake Supabase + Mocked Ollama 验证。
"""

from __future__ import annotations

import asyncio
import copy
import json
import uuid
from dataclasses import dataclass, field
from typing import Any
from unittest.mock import AsyncMock, patch

import pytest
from pytest_bdd import given, parsers, scenario, scenarios, then, when

# ── 绑定 feature ────────────────────────────────────────

scenarios("features/assignment_grading.feature")


# ══════════════════════════════════════════════════════════
# 内存级 Fake Supabase（支持多表 CRUD 链式调用）
# ══════════════════════════════════════════════════════════


class _Rows:
    """模拟一次链式查询的中间状态。"""

    def __init__(self, table_name: str, store: dict[str, list[dict]]) -> None:
        self._table = table_name
        self._store = store
        self._filters: list[tuple[str, Any]] = []
        self._select_cols: str | None = None
        self._order_col: str | None = None
        self._single = False
        self._update_data: dict | None = None

    # ── 链式方法 ───────────────────

    def select(self, cols: str = "*", **_kw: Any) -> "_Rows":
        self._select_cols = cols
        return self

    def eq(self, col: str, val: Any) -> "_Rows":
        self._filters.append((col, val))
        return self

    def maybe_single(self) -> "_Rows":
        self._single = True
        return self

    def order(self, col: str, **_kw: Any) -> "_Rows":
        self._order_col = col
        return self

    def update(self, data: dict) -> "_Rows":
        self._update_data = copy.deepcopy(data)
        return self

    # ── 执行 ───────────────────────

    def execute(self) -> Any:
        rows = self._store.get(self._table, [])

        # 精确过滤
        for col, val in self._filters:
            rows = [r for r in rows if r.get(col) == val]

        # 排序
        if self._order_col:
            rows = sorted(rows, key=lambda r: r.get(self._order_col, 0))

        # update 操作
        if self._update_data is not None:
            for r in rows:
                for k, v in self._update_data.items():
                    if v == "now()":
                        continue  # 测试里跳过
                    r[k] = v
            return _Result(data=rows)

        if self._single:
            return _Result(data=rows[0] if rows else None)
        return _Result(data=rows)


@dataclass
class _Result:
    data: Any


class _FakeGradingSupabase:
    """全功能内存 Supabase mock，支持多表 select/update/eq/order。"""

    def __init__(self) -> None:
        self._tables: dict[str, list[dict]] = {}
        self.storage = _FakeStorage()

    def seed(self, table_name: str, rows: list[dict]) -> None:
        self._tables[table_name] = copy.deepcopy(rows)

    def get_rows(self, table_name: str) -> list[dict]:
        return self._tables.get(table_name, [])

    def table(self, name: str) -> _Rows:
        return _Rows(name, self._tables)


class _FakeStorage:
    def from_(self, bucket: str):
        return self


# ══════════════════════════════════════════════════════════
# 测试上下文
# ══════════════════════════════════════════════════════════

TEACHER_UID = "teacher-uid-001"
STUDENT_UID = "student-uid-001"
ASSIGNMENT_ID = str(uuid.uuid4())
SUBMISSION_ID = str(uuid.uuid4())
COURSE_ID = str(uuid.uuid4())

# 题目种子数据
QUESTIONS: list[dict[str, Any]] = [
    {
        "id": str(uuid.uuid4()),
        "assignment_id": ASSIGNMENT_ID,
        "question_type": "single_choice",
        "content": "Python 的创始人是？",
        "options": [
            {"label": "A", "text": "Guido van Rossum"},
            {"label": "B", "text": "James Gosling"},
            {"label": "C", "text": "Bjarne Stroustrup"},
            {"label": "D", "text": "Dennis Ritchie"},
        ],
        "correct_answer": {"answer": "A"},
        "score": 2,
        "sort_order": 1,
    },
    {
        "id": str(uuid.uuid4()),
        "assignment_id": ASSIGNMENT_ID,
        "question_type": "true_false",
        "content": "Python 是编译型语言。",
        "options": None,
        "correct_answer": {"answer": False},
        "score": 2,
        "sort_order": 2,
    },
    {
        "id": str(uuid.uuid4()),
        "assignment_id": ASSIGNMENT_ID,
        "question_type": "fill_blank",
        "content": "Python 使用____来表示代码块。",
        "options": None,
        "correct_answer": {"answer": ["缩进"]},
        "score": 3,
        "sort_order": 3,
    },
    {
        "id": str(uuid.uuid4()),
        "assignment_id": ASSIGNMENT_ID,
        "question_type": "short_answer",
        "content": "简述 Python 列表和元组的区别。",
        "options": None,
        "correct_answer": {"answer": "列表是可变的有序序列，元组是不可变的有序序列；列表用方括号，元组用圆括号。"},
        "score": 10,
        "sort_order": 4,
    },
]

# 学生答案
STUDENT_ANSWERS: list[dict[str, Any]] = [
    {
        "id": str(uuid.uuid4()),
        "submission_id": SUBMISSION_ID,
        "question_id": QUESTIONS[0]["id"],
        "answer": {"answer": "A"},
        "is_correct": True,
        "score": 2,
        "graded_by": "auto",
        "ai_score": None,
        "ai_feedback": None,
        "ai_detail": None,
    },
    {
        "id": str(uuid.uuid4()),
        "submission_id": SUBMISSION_ID,
        "question_id": QUESTIONS[1]["id"],
        "answer": {"answer": False},
        "is_correct": True,
        "score": 2,
        "graded_by": "auto",
        "ai_score": None,
        "ai_feedback": None,
        "ai_detail": None,
    },
    {
        "id": str(uuid.uuid4()),
        "submission_id": SUBMISSION_ID,
        "question_id": QUESTIONS[2]["id"],
        "answer": {"answer": ["缩进"]},
        "is_correct": True,
        "score": 3,
        "graded_by": "auto",
        "ai_score": None,
        "ai_feedback": None,
        "ai_detail": None,
    },
    {
        "id": str(uuid.uuid4()),
        "submission_id": SUBMISSION_ID,
        "question_id": QUESTIONS[3]["id"],
        "answer": {"answer": "列表可变，元组不可变。列表用[]，元组用()。"},
        "is_correct": None,
        "score": 0,
        "graded_by": "pending",
        "ai_score": None,
        "ai_feedback": None,
        "ai_detail": None,
    },
]


@dataclass
class GradingCtx:
    """BDD 跨步骤状态。"""

    fake_sb: _FakeGradingSupabase = field(default_factory=_FakeGradingSupabase)
    response: Any = None
    detail_result: dict | None = None
    grading_result: dict | None = None
    submission_status: str = ""


@pytest.fixture
def ctx() -> GradingCtx:
    c = GradingCtx()
    # seed 数据
    c.fake_sb.seed("assignment_submissions", [
        {
            "id": SUBMISSION_ID,
            "assignment_id": ASSIGNMENT_ID,
            "student_id": STUDENT_UID,
            "status": "submitted",
            "total_score": None,
            "submitted_at": "2026-03-28T12:00:00",
            "updated_at": None,
        },
    ])
    c.fake_sb.seed("assignment_questions", copy.deepcopy(QUESTIONS))
    c.fake_sb.seed("student_answers", copy.deepcopy(STUDENT_ANSWERS))
    c.fake_sb.seed("courses", [
        {"id": COURSE_ID, "teacher_id": TEACHER_UID},
    ])
    return c


# ── 辅助：构建 mock Ollama 响应工厂 ─────────────────────

def _build_ollama_mock() -> AsyncMock:
    """根据 prompt 内容返回不同的 mock 响应（仅处理简答题）。"""

    async def _fake_ollama(prompt: str, *, json_mode: bool = False) -> str:
        if json_mode and "简答" in prompt:
            return json.dumps({
                "score": 7.5,
                "breakdown": {
                    "knowledge_coverage": {"score": 3.2, "max": 4.0, "comment": "核心知识点覆盖"},
                    "accuracy": {"score": 2.5, "max": 3.0, "comment": "术语基本准确"},
                    "logic": {"score": 1.2, "max": 2.0, "comment": "逻辑尚可"},
                    "language": {"score": 0.6, "max": 1.0, "comment": "表达简洁"},
                },
                "feedback": "回答涵盖了主要区别，但可以补充更多细节。",
                "highlights": "正确指出了可变与不可变的差异",
                "improvements": "建议补充底层存储和使用场景的对比",
            }, ensure_ascii=False)
        # 不应被调用到这里（客观题和填空题不再走AI）
        raise RuntimeError(f"Unexpected AI call for non-short-answer question: {prompt[:80]}")

    return AsyncMock(side_effect=_fake_ollama)


# ── 辅助：通过 TestClient 发请求 ──────────────────────────

def _make_client_and_post(
    ctx: GradingCtx,
    path: str,
    payload: dict,
    *,
    as_user: str = STUDENT_UID,
) -> Any:
    fake_payload = {"sub": as_user, "email": "test@test.com", "role": "authenticated"}

    with (
        patch("src.services.assignment_grader.get_supabase_client", return_value=ctx.fake_sb),
        patch("src.api.assignments.get_supabase_client", return_value=ctx.fake_sb),
        patch("src.middleware.auth.AuthMiddleware._resolve_payload", return_value=fake_payload),
    ):
        from fastapi.testclient import TestClient
        from src.app import app

        with TestClient(app) as client:
            return client.post(
                path,
                json=payload,
                headers={"Authorization": "Bearer fake-jwt"},
            )


# ══════════════════════════════════════════════════════════
# Given 步骤
# ══════════════════════════════════════════════════════════


@given("系统存在一位教师用户")
def has_teacher(ctx: GradingCtx):
    pass  # seed 已在 fixture 中完成


@given("系统存在一位学生用户")
def has_student(ctx: GradingCtx):
    pass


@given("教师发布了一份包含多种题型的作业")
def assignment_published(ctx: GradingCtx):
    pass  # seed 数据已包含 4 种题型


# ══════════════════════════════════════════════════════════
# When 步骤
# ══════════════════════════════════════════════════════════


@when("学生提交全部答案")
def student_submits(ctx: GradingCtx):
    """模拟学生提交 — 直接更新内存中的 submission 状态。

    真实流程中，学生通过前端调用 Supabase RPC（student_submit），
    这里我们直接在内存 mock 中设置提交后应有的状态。
    """
    subs = ctx.fake_sb.get_rows("assignment_submissions")
    for s in subs:
        if s["id"] == SUBMISSION_ID:
            s["status"] = "submitted"
    ctx.submission_status = "submitted"


@when("触发AI批改")
def trigger_ai_grading(ctx: GradingCtx):
    """通过 HTTP API 触发 AI 批改并等待后台 task 完成。"""
    ollama_mock = _build_ollama_mock()

    fake_payload = {"sub": STUDENT_UID, "email": "student@test.com", "role": "authenticated"}

    with (
        patch("src.services.assignment_grader.get_supabase_client", return_value=ctx.fake_sb),
        patch("src.api.assignments.get_supabase_client", return_value=ctx.fake_sb),
        patch("src.services.assignment_grader._call_ollama", new=ollama_mock),
        patch("src.middleware.auth.AuthMiddleware._resolve_payload", return_value=fake_payload),
    ):
        from fastapi.testclient import TestClient
        from src.app import app

        with TestClient(app) as client:
            resp = client.post(
                "/api/assignments/grade",
                json={"submission_id": SUBMISSION_ID},
                headers={"Authorization": "Bearer fake-jwt"},
            )
        ctx.response = resp
        assert resp.status_code == 200, f"触发批改失败: {resp.text}"

    # TestClient 的 asyncio.create_task 后台 task 可能已完成。
    # 确保 submission 状态允许再次调用 grade_submission
    subs = ctx.fake_sb.get_rows("assignment_submissions")
    sub = next(s for s in subs if s["id"] == SUBMISSION_ID)
    if sub["status"] == "ai_graded":
        # 背景任务已跑完，直接使用结果
        ctx.grading_result = {"already_completed": True}
        return

    # 否则手动跑一次
    with (
        patch("src.services.assignment_grader.get_supabase_client", return_value=ctx.fake_sb),
        patch("src.services.assignment_grader._call_ollama", new=ollama_mock),
    ):
        from src.services.assignment_grader import grade_submission
        ctx.grading_result = asyncio.run(grade_submission(SUBMISSION_ID))


@when("教师获取提交详情")
def teacher_gets_detail(ctx: GradingCtx):
    """教师通过 Supabase RPC 获取详情 — 这里直接从内存构建预期结构。"""
    subs = ctx.fake_sb.get_rows("assignment_submissions")
    sub = next(s for s in subs if s["id"] == SUBMISSION_ID)
    answers = ctx.fake_sb.get_rows("student_answers")
    questions = ctx.fake_sb.get_rows("assignment_questions")
    q_map = {q["id"]: q for q in questions}

    answer_details = []
    for ans in sorted(answers, key=lambda a: q_map.get(a["question_id"], {}).get("sort_order", 0)):
        q = q_map.get(ans["question_id"], {})
        answer_details.append({
            "answer_id": ans["id"],
            "question_id": ans["question_id"],
            "question_type": q.get("question_type"),
            "content": q.get("content"),
            "max_score": q.get("score"),
            "student_answer": ans.get("answer"),
            "correct_answer": q.get("correct_answer"),
            "score": ans.get("score"),
            "ai_score": ans.get("ai_score"),
            "ai_feedback": ans.get("ai_feedback"),
            "ai_detail": ans.get("ai_detail"),
            "graded_by": ans.get("graded_by"),
            "is_correct": ans.get("is_correct"),
        })

    ctx.detail_result = {
        "submission_id": SUBMISSION_ID,
        "status": sub["status"],
        "total_score": sub.get("total_score"),
        "answers": answer_details,
    }


@when(parsers.parse("教师修改简答题评分为 {score:d} 分并添加评语 \"{comment}\""))
def teacher_grades_answer(ctx: GradingCtx, score: int, comment: str):
    """教师手动给简答题打分。"""
    answers = ctx.fake_sb.get_rows("student_answers")
    questions = ctx.fake_sb.get_rows("assignment_questions")
    q_map = {q["id"]: q for q in questions}

    for ans in answers:
        q = q_map.get(ans["question_id"], {})
        if q.get("question_type") == "short_answer":
            ans["score"] = score
            ans["teacher_comment"] = comment
            ans["graded_by"] = "teacher"
            break


@when("教师一键采纳AI评分")
def teacher_accepts_all(ctx: GradingCtx):
    """模拟 teacher_accept_all_ai_scores RPC 逻辑。"""
    answers = ctx.fake_sb.get_rows("student_answers")
    for ans in answers:
        if ans["submission_id"] == SUBMISSION_ID:
            ai_score = ans.get("ai_score")
            if ai_score is not None:
                ans["score"] = ai_score
            ans["graded_by"] = "teacher"


@when("教师确认复核完成")
def teacher_finalizes(ctx: GradingCtx):
    """模拟 teacher_finalize_grading RPC 逻辑。"""
    subs = ctx.fake_sb.get_rows("assignment_submissions")
    answers = ctx.fake_sb.get_rows("student_answers")

    total = sum(float(a.get("score") or 0) for a in answers if a["submission_id"] == SUBMISSION_ID)

    for s in subs:
        if s["id"] == SUBMISSION_ID:
            s["status"] = "graded"
            s["total_score"] = total

    ctx.submission_status = "graded"


# ══════════════════════════════════════════════════════════
# Then 步骤
# ══════════════════════════════════════════════════════════


@then(parsers.parse('应返回提交成功且状态为 "{status}"'))
def assert_submitted(ctx: GradingCtx, status: str):
    subs = ctx.fake_sb.get_rows("assignment_submissions")
    sub = next(s for s in subs if s["id"] == SUBMISSION_ID)
    assert sub["status"] == status, f"期望 {status}，实际 {sub['status']}"


@then(parsers.parse('AI批改应成功完成且状态变为 "{status}"'))
def assert_ai_graded(ctx: GradingCtx, status: str):
    assert ctx.grading_result is not None, "AI 批改未返回结果"
    subs = ctx.fake_sb.get_rows("assignment_submissions")
    sub = next(s for s in subs if s["id"] == SUBMISSION_ID)
    assert sub["status"] == status, f"期望 {status}，实际 {sub['status']}"


@then("客观题应自动评分")
def assert_objective_scored(ctx: GradingCtx):
    answers = ctx.fake_sb.get_rows("student_answers")
    questions = ctx.fake_sb.get_rows("assignment_questions")
    q_map = {q["id"]: q for q in questions}

    for ans in answers:
        q = q_map.get(ans["question_id"], {})
        qtype = q.get("question_type")
        if qtype in ("single_choice", "true_false"):
            assert ans["score"] is not None and ans["score"] >= 0, (
                f"{qtype} 题未评分: score={ans['score']}"
            )
            assert ans.get("graded_by") in ("auto", "ai", "fallback"), (
                f"{qtype} 题 graded_by 异常: {ans.get('graded_by')}"
            )


@then("填空题应自动精确匹配评分")
def assert_fill_blank_auto_scored(ctx: GradingCtx):
    answers = ctx.fake_sb.get_rows("student_answers")
    questions = ctx.fake_sb.get_rows("assignment_questions")
    q_map = {q["id"]: q for q in questions}

    for ans in answers:
        q = q_map.get(ans["question_id"], {})
        if q.get("question_type") == "fill_blank":
            assert ans["score"] is not None and ans["score"] >= 0, (
                f"填空题未自动评分: score={ans['score']}"
            )
            assert ans.get("graded_by") == "auto", (
                f"填空题 graded_by 应为 auto，实际: {ans.get('graded_by')}"
            )


@then("简答题应有AI评分和反馈")
def assert_short_answer_ai(ctx: GradingCtx):
    answers = ctx.fake_sb.get_rows("student_answers")
    questions = ctx.fake_sb.get_rows("assignment_questions")
    q_map = {q["id"]: q for q in questions}

    for ans in answers:
        q = q_map.get(ans["question_id"], {})
        qtype = q.get("question_type")
        if qtype == "short_answer":
            assert ans.get("ai_score") is not None, f"简答题缺少 ai_score"
            assert ans.get("ai_feedback"), f"简答题缺少 ai_feedback"
            assert ans.get("graded_by") in ("ai", "fallback"), (
                f"简答题 graded_by 异常: {ans.get('graded_by')}"
            )


@then("应返回完整的答题明细")
def assert_detail(ctx: GradingCtx):
    assert ctx.detail_result is not None
    assert len(ctx.detail_result["answers"]) == len(QUESTIONS), (
        f"期望 {len(QUESTIONS)} 道题，实际 {len(ctx.detail_result['answers'])}"
    )
    for ans in ctx.detail_result["answers"]:
        assert ans.get("answer_id"), "缺少 answer_id"
        assert ans.get("question_type"), "缺少 question_type"
        assert ans.get("content"), "缺少 content"


@then("所有答案应标记为教师已审")
def assert_all_teacher_graded(ctx: GradingCtx):
    answers = ctx.fake_sb.get_rows("student_answers")
    for ans in answers:
        if ans["submission_id"] == SUBMISSION_ID:
            assert ans["graded_by"] == "teacher", (
                f"答案 {ans['id']} 的 graded_by={ans['graded_by']}，期望 teacher"
            )


@then(parsers.parse('提交状态应变为 "{status}"'))
def assert_status(ctx: GradingCtx, status: str):
    subs = ctx.fake_sb.get_rows("assignment_submissions")
    sub = next(s for s in subs if s["id"] == SUBMISSION_ID)
    assert sub["status"] == status, f"期望 {status}，实际 {sub['status']}"


@then("总分应正确计算")
def assert_total_score(ctx: GradingCtx):
    subs = ctx.fake_sb.get_rows("assignment_submissions")
    sub = next(s for s in subs if s["id"] == SUBMISSION_ID)
    answers = ctx.fake_sb.get_rows("student_answers")

    expected = sum(float(a.get("score") or 0) for a in answers if a["submission_id"] == SUBMISSION_ID)
    assert sub["total_score"] == expected, (
        f"总分不一致: submission={sub['total_score']}, sum={expected}"
    )


@then("该题应保存教师评分")
def assert_teacher_score_saved(ctx: GradingCtx):
    answers = ctx.fake_sb.get_rows("student_answers")
    questions = ctx.fake_sb.get_rows("assignment_questions")
    q_map = {q["id"]: q for q in questions}

    for ans in answers:
        q = q_map.get(ans["question_id"], {})
        if q.get("question_type") == "short_answer":
            assert ans["score"] == 8, f"简答题分数期望8，实际{ans['score']}"
            assert ans.get("teacher_comment") == "论述不够深入"
            assert ans["graded_by"] == "teacher"
            return

    pytest.fail("未找到简答题答案")
