"""教师作业题目生成 — BDD step 实现"""

from __future__ import annotations

import json
from typing import Any
from unittest.mock import AsyncMock, patch

import httpx
import pytest
from pytest_bdd import given, parsers, scenario, scenarios, then, when

from tests.bdd.conftest import BDDContext, build_mock_deepseek_response

# 绑定 feature 文件中的所有场景
scenarios("features/assignment_generation.feature")


# ── 背景 (Given) ─────────────────────────────────────────


@given("教师已通过身份认证")
def teacher_authenticated(ctx: BDDContext):
    ctx.user_id = "teacher-uid-001"


@given(parsers.parse('教师拥有课程 "{course_name}"'))
def teacher_owns_course(ctx: BDDContext, course_name: str):
    ctx.course_id = "course-001"
    ctx.is_course_owner = True


# ── 文件上传 (Given) ──────────────────────────────────────


@given(parsers.parse('教师上传了参考资料 "{filename}"'))
def teacher_uploaded_file(ctx: BDDContext, filename: str):
    content = (
        "Python 是一门解释型、面向对象的高级编程语言。\n"
        "Python 支持多种数据类型，包括 int、float、str、list、dict、tuple、set。\n"
        "列表（list）是可变的有序序列，元组（tuple）是不可变的有序序列。\n"
        "字典（dict）是键值对的集合，键必须是不可变类型。\n"
        "Python 使用缩进来表示代码块，而非大括号。\n"
        "def 关键字用于定义函数，class 关键字用于定义类。\n"
    )
    path_in_bucket = f"{ctx.course_id}/temp/uid-1/{filename}"
    ctx.uploaded_files[path_in_bucket] = content.encode("utf-8")
    ctx.file_paths.append(f"assignment-materials/{path_in_bucket}")


@given("教师未上传任何参考资料")
def teacher_no_files(ctx: BDDContext):
    ctx.uploaded_files.clear()
    ctx.file_paths.clear()


@given(parsers.parse("教师上传了 {count:d} 个参考资料文件"))
def teacher_uploaded_many_files(ctx: BDDContext, count: int):
    for i in range(count):
        path = f"{ctx.course_id}/temp/uid-{i}/file_{i}.txt"
        ctx.uploaded_files[path] = f"内容{i}".encode("utf-8")
        ctx.file_paths.append(f"assignment-materials/{path}")


@given("当前用户不是该课程的教师")
def user_not_course_teacher(ctx: BDDContext):
    ctx.is_course_owner = False


# ── 题目配置 (Given) ──────────────────────────────────────


@given("教师配置了题目:")
def teacher_configured_questions(ctx: BDDContext, datatable):
    """解析 Gherkin DataTable 为 question_config dict。

    pytest-bdd datatable 格式为 list[list[str]]，第一行是表头。
    """
    headers = datatable[0]
    for row in datatable[1:]:
        row_dict = dict(zip(headers, row))
        qtype = row_dict["题型"].strip()
        count = int(row_dict["数量"])
        score = float(row_dict["每题分值"])
        ctx.question_config[qtype] = {
            "count": count,
            "score_per_question": score,
        }


@given(parsers.parse('教师设置了提示词 "{prompt}"'))
def teacher_set_prompt(ctx: BDDContext, prompt: str):
    ctx.ai_prompt = prompt


# ── 执行生成 (When) ───────────────────────────────────────


@when("教师请求 AI 生成题目")
def teacher_requests_generation(ctx: BDDContext):
    """通过 HTTP API 发送生成请求，mock 掉 Supabase、DeepSeek 和 Auth。"""
    from tests.bdd.conftest import _FakeSupabaseClient

    # 构建 mock DeepSeek 响应
    mock_ai_response = build_mock_deepseek_response(ctx.question_config)
    mock_json_str = json.dumps(mock_ai_response, ensure_ascii=False)

    fake_sb = _FakeSupabaseClient(
        files=ctx.uploaded_files,
        course_owner=ctx.is_course_owner,
    )

    # mock httpx 响应（需要 request 实例才能调用 raise_for_status）
    mock_request = httpx.Request("POST", "https://api.deepseek.com/v1/chat/completions")

    # 构造 _call_deepseek 的 mock，直接返回 JSON 字符串
    async_call_mock = AsyncMock(return_value=mock_json_str)

    request_body = {
        "course_id": ctx.course_id,
        "title": "Python入门测试",
        "description": "Python 基础语法练习",
        "file_paths": ctx.file_paths,
        "question_config": ctx.question_config,
        "ai_prompt": ctx.ai_prompt,
    }

    # Mock 认证中间件的 _resolve_payload 以返回假用户
    fake_payload = {"sub": ctx.user_id, "email": "teacher@test.com", "role": "authenticated"}

    with (
        patch(
            "src.services.assignment_generator.get_supabase_client",
            return_value=fake_sb,
        ),
        patch(
            "src.api.assignments.get_supabase_client",
            return_value=fake_sb,
        ),
        patch(
            "src.services.assignment_generator._call_deepseek",
            new=async_call_mock,
        ),
        patch(
            "src.middleware.auth.AuthMiddleware._resolve_payload",
            return_value=fake_payload,
        ),
    ):
        from fastapi.testclient import TestClient
        from src.app import app

        with TestClient(app) as client:
            resp = client.post(
                "/api/assignments/generate",
                json=request_body,
                headers={"Authorization": "Bearer fake-jwt-for-test"},
            )

    ctx.response = resp


# ── 验证结果 (Then) ───────────────────────────────────────


@then("应该成功返回生成结果")
def assert_success(ctx: BDDContext):
    assert ctx.response is not None
    assert ctx.response.status_code == 200, (
        f"期望 200，实际 {ctx.response.status_code}: {ctx.response.text}"
    )
    ctx.result = ctx.response.json()


@then(parsers.parse("生成的题目总数应为 {count:d}"))
def assert_question_count(ctx: BDDContext, count: int):
    assert ctx.result is not None
    questions = ctx.result["questions"]
    assert len(questions) == count, (
        f"期望 {count} 道题目，实际 {len(questions)}"
    )


@then("每道题目都应包含完整结构")
def assert_question_structure(ctx: BDDContext):
    for i, q in enumerate(ctx.result["questions"]):
        assert "question_type" in q, f"题目 {i + 1} 缺少 question_type"
        assert "content" in q, f"题目 {i + 1} 缺少 content"
        assert "correct_answer" in q, f"题目 {i + 1} 缺少 correct_answer"
        assert "explanation" in q, f"题目 {i + 1} 缺少 explanation"
        assert "score" in q, f"题目 {i + 1} 缺少 score"
        assert "sort_order" in q, f"题目 {i + 1} 缺少 sort_order"


@then("单选题应有4个选项且答案为单个字母")
def assert_single_choice(ctx: BDDContext):
    for q in ctx.result["questions"]:
        if q["question_type"] == "single_choice":
            assert isinstance(q["options"], list), "单选题缺少选项"
            assert len(q["options"]) >= 2, "单选题选项不足"
            ans = q["correct_answer"]["answer"]
            assert isinstance(ans, str) and len(ans) == 1, (
                f"单选题答案应为单个字母，实际: {ans}"
            )


@then("多选题应有选项且答案为字母数组")
def assert_multiple_choice(ctx: BDDContext):
    for q in ctx.result["questions"]:
        if q["question_type"] == "multiple_choice":
            assert isinstance(q["options"], list), "多选题缺少选项"
            ans = q["correct_answer"]["answer"]
            assert isinstance(ans, list), f"多选题答案应为数组，实际: {type(ans)}"
            for a in ans:
                assert isinstance(a, str), f"多选题答案元素应为字符串: {a}"


@then("判断题答案应为布尔值")
def assert_true_false(ctx: BDDContext):
    for q in ctx.result["questions"]:
        if q["question_type"] == "true_false":
            ans = q["correct_answer"]["answer"]
            assert isinstance(ans, bool), f"判断题答案应为布尔值，实际: {type(ans)}"


@then("填空题答案应为数组")
def assert_fill_blank(ctx: BDDContext):
    for q in ctx.result["questions"]:
        if q["question_type"] == "fill_blank":
            ans = q["correct_answer"]["answer"]
            assert isinstance(ans, list), f"填空题答案应为数组，实际: {type(ans)}"


@then("简答题答案应为字符串")
def assert_short_answer(ctx: BDDContext):
    for q in ctx.result["questions"]:
        if q["question_type"] == "short_answer":
            ans = q["correct_answer"]["answer"]
            assert isinstance(ans, str), f"简答题答案应为字符串，实际: {type(ans)}"


@then("每道题应有对应的分值和排序")
def assert_score_and_order(ctx: BDDContext):
    for i, q in enumerate(ctx.result["questions"]):
        assert q["score"] >= 0, f"题目 {i + 1} 分值不应为负"
        assert q["sort_order"] == i + 1, (
            f"题目 {i + 1} 排序应为 {i + 1}，实际 {q['sort_order']}"
        )


@then(parsers.parse('应该返回错误 {status:d} "{message}"'))
def assert_error_response(ctx: BDDContext, status: int, message: str):
    assert ctx.response is not None
    assert ctx.response.status_code == status, (
        f"期望状态码 {status}，实际 {ctx.response.status_code}: {ctx.response.text}"
    )
    body = ctx.response.json()
    # Pydantic 422 的 detail 是 list，其他 HTTPException 是 str
    detail = body.get("detail", "")
    text = json.dumps(detail, ensure_ascii=False) if isinstance(detail, list) else str(detail)
    assert message in text, (
        f'期望错误消息包含 "{message}"，实际: "{text}"'
    )
