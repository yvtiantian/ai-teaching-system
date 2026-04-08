"""AI 学情分析服务 — 调用 DeepSeek 生成学情报告和错因分析"""

from __future__ import annotations

import asyncio
import json
from typing import Any, AsyncIterator

import httpx
from loguru import logger

from src.core.settings import settings
from src.core.supabase_client import get_supabase_client

_DEEPSEEK_BASE = settings.deepseek.base_url.rstrip("/")
_DEEPSEEK_MODEL = settings.deepseek.default_model
_DEEPSEEK_API_KEY = settings.deepseek.api_key
_TIMEOUT = 120

# ── Prompt 模板 ──────────────────────────────────────────

_CLASS_REPORT_PROMPT = """\
你是一位资深的教学分析专家。请根据以下班级作业数据，生成一份学情分析报告。

课程信息:
- 选课人数: {total_students}
- 已发布作业数: {assignment_count}

各作业数据:
{assignments_detail}

请用 Markdown 格式输出报告，包含以下部分：
1. **整体学情概述** — 用 2-3 句话概括班级整体表现
2. **成绩趋势分析** — 分析各次作业平均分走势，是进步还是退步
3. **薄弱环节诊断** — 指出哪些作业/知识点掌握较差
4. **教学建议** — 给出 3-5 条具体可操作的教学改进建议
5. **需重点关注的学生** — 如果数据中有低提交率或低分情况，提醒教师关注

注意：
- 使用中文
- 数据驱动，不要空泛
- 建议要具体可操作
- 如果数据不足以得出结论，如实说明"""

_ERROR_ANALYSIS_PROMPT = """\
你是一位专业的教学分析助手。请分析以下高错误率题目的常见错误模式。

题目信息:
- 题型: {question_type}
- 题目内容: {content}
- 正确答案: {correct_answer}
- 错误率: {error_rate}%
- 作答人数: {total_answers}

常见错误答案分布:
{wrong_answers_detail}

请用 Markdown 格式输出分析，包含：
1. **错因分析** — 学生为什么会选错/答错？常见误区是什么？
2. **知识点定位** — 这道题考查的核心知识点是什么？
3. **教学改进建议** — 教师应该如何针对性地补充讲解？
4. **变式练习建议** — 建议出什么样的练习来巩固这个知识点？

注意：使用中文，具体实用。"""

_TYPE_LABELS: dict[str, str] = {
    "single_choice": "单选题",
    "multiple_choice": "多选题",
    "true_false": "判断题",
    "fill_blank": "填空题",
    "short_answer": "简答题",
}


# ══════════════════════════════════════════════════════════
# 学情报告
# ══════════════════════════════════════════════════════════

async def load_class_report_context(
    course_id: str,
    teacher_id: str,
) -> dict[str, Any]:
    """从数据库加载课程分析数据，构建 prompt 上下文。"""
    sb = get_supabase_client()

    # 验证课程归属
    course_result = await asyncio.to_thread(
        lambda: sb.table("courses")
        .select("id, name")
        .eq("id", course_id)
        .eq("teacher_id", teacher_id)
        .maybe_single()
        .execute()
    )
    if not course_result.data:
        raise PermissionError("课程不存在或无权操作")

    # 调用 RPC 获取分析数据
    analytics_result = await asyncio.to_thread(
        lambda: sb.rpc(
            "teacher_get_course_analytics",
            {"p_course_id": course_id},
        ).execute()
    )
    data = analytics_result.data
    if not data:
        raise ValueError("暂无分析数据")

    # 格式化作业详情
    assignments = data.get("assignments", [])
    lines = []
    for i, a in enumerate(assignments, 1):
        lines.append(
            f"  {i}. 《{a['title']}》- 总分{a['total_score']}, "
            f"提交{a['submitted_count']}人, "
            f"平均分{a.get('avg_score', '无')}, "
            f"最高{a.get('max_score', '无')}, "
            f"最低{a.get('min_score', '无')}"
        )

    prompt = _CLASS_REPORT_PROMPT.format(
        total_students=data.get("total_students", 0),
        assignment_count=data.get("assignment_count", 0),
        assignments_detail="\n".join(lines) if lines else "暂无作业数据",
    )

    return {
        "system_prompt": prompt,
        "course_name": course_result.data["name"],
    }


async def stream_class_report(context: dict[str, Any]) -> AsyncIterator[str]:
    """流式调用 DeepSeek 生成学情报告。"""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{_DEEPSEEK_BASE}/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {_DEEPSEEK_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": _DEEPSEEK_MODEL,
                "messages": [
                    {"role": "system", "content": "你是一位专业的教学数据分析师。"},
                    {"role": "user", "content": context["system_prompt"]},
                ],
                "temperature": 0.4,
                "stream": True,
            },
            timeout=_TIMEOUT,
        )
        response.raise_for_status()

        async for line in response.aiter_lines():
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload.strip() == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
                delta = chunk.get("choices", [{}])[0].get("delta", {})
                content = delta.get("content")
                if content:
                    yield content
            except json.JSONDecodeError:
                continue


# ══════════════════════════════════════════════════════════
# 错因分析
# ══════════════════════════════════════════════════════════

async def load_error_analysis_context(
    assignment_id: str,
    question_id: str,
    teacher_id: str,
) -> dict[str, Any]:
    """加载题目和错误答案数据，构建错因分析 prompt。"""
    sb = get_supabase_client()

    # 验证作业归属
    assignment_result = await asyncio.to_thread(
        lambda: sb.table("assignments")
        .select("id, course_id, courses!inner(teacher_id)")
        .eq("id", assignment_id)
        .maybe_single()
        .execute()
    )
    if not assignment_result.data:
        raise ValueError("作业不存在")

    course_data = assignment_result.data.get("courses", {})
    if isinstance(course_data, dict) and course_data.get("teacher_id") != teacher_id:
        raise PermissionError("无权操作此作业")

    # 获取题目信息
    question_result = await asyncio.to_thread(
        lambda: sb.table("assignment_questions")
        .select("id, question_type, content, correct_answer, score")
        .eq("id", question_id)
        .eq("assignment_id", assignment_id)
        .maybe_single()
        .execute()
    )
    if not question_result.data:
        raise ValueError("题目不存在")

    q = question_result.data

    # 获取错误答案分布
    answers_result = await asyncio.to_thread(
        lambda: sb.rpc("teacher_get_question_analysis", {"p_assignment_id": assignment_id}).execute()
    )
    analysis_data = answers_result.data or {}
    questions_list = analysis_data.get("questions", [])
    question_stats = next((x for x in questions_list if x.get("question_id") == question_id), {})

    # 获取常见错误答案
    wrong_result = await asyncio.to_thread(
        lambda: sb.table("student_answers")
        .select("answer")
        .eq("question_id", question_id)
        .eq("is_correct", False)
        .execute()
    )
    wrong_answers: list[dict] = wrong_result.data or []

    # 聚合错误答案
    answer_counts: dict[str, int] = {}
    for wa in wrong_answers:
        key = json.dumps(wa.get("answer"), ensure_ascii=False, default=str)
        answer_counts[key] = answer_counts.get(key, 0) + 1

    sorted_answers = sorted(answer_counts.items(), key=lambda x: x[1], reverse=True)[:5]
    wrong_lines = [f"  - {ans}: {cnt}人" for ans, cnt in sorted_answers]

    correct_answer_str = json.dumps(q["correct_answer"], ensure_ascii=False, default=str)

    prompt = _ERROR_ANALYSIS_PROMPT.format(
        question_type=_TYPE_LABELS.get(q["question_type"], q["question_type"]),
        content=q["content"],
        correct_answer=correct_answer_str,
        error_rate=question_stats.get("correct_rate", 0),
        total_answers=question_stats.get("total_answers", 0),
        wrong_answers_detail="\n".join(wrong_lines) if wrong_lines else "无数据",
    )

    return {"system_prompt": prompt}


async def stream_error_analysis(context: dict[str, Any]) -> AsyncIterator[str]:
    """流式调用 DeepSeek 生成错因分析。"""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{_DEEPSEEK_BASE}/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {_DEEPSEEK_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": _DEEPSEEK_MODEL,
                "messages": [
                    {"role": "system", "content": "你是一位专业的教学诊断分析师。"},
                    {"role": "user", "content": context["system_prompt"]},
                ],
                "temperature": 0.4,
                "stream": True,
            },
            timeout=_TIMEOUT,
        )
        response.raise_for_status()

        async for line in response.aiter_lines():
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload.strip() == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
                delta = chunk.get("choices", [{}])[0].get("delta", {})
                content = delta.get("content")
                if content:
                    yield content
            except json.JSONDecodeError:
                continue
