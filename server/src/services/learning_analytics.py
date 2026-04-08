"""AI 学情分析服务 — 调用 DeepSeek 生成错因分析"""

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

_ERROR_ANALYSIS_PROMPT = """\
你是一位专业的教学分析助手。请分析以下高错误率题目的常见错误模式。

题目信息:
- 题型: {question_type}
- 题目内容: {content}
{options_section}\
- 正确答案: {correct_answer}
- 错误率: {error_rate}%
- 作答人数: {total_answers}

常见错误答案分布:
{wrong_answers_detail}

请用 Markdown 格式输出分析，包含：
1. **错因分析** — 学生为什么会选错/答错？分析可能原因和思维误区。
2. **知识点定位** — 这道题考查的核心知识点是什么？
3. **教学改进建议** — 教师应该如何针对性地补充讲解？

注意：使用中文，具体实用，结合选项内容和错答分布做深入分析。"""

_TYPE_LABELS: dict[str, str] = {
    "single_choice": "单选题",
    "multiple_choice": "多选题",
    "true_false": "判断题",
    "fill_blank": "填空题",
    "short_answer": "简答题",
}

# ══════════════════════════════════════════════════════════
# 答案格式化辅助
# ══════════════════════════════════════════════════════════

def _format_answer_display(
    ans_raw: str, q_type: str, option_map: dict[str, str]
) -> str:
    """将原始答案 JSON 转为人类可读的展示文本。"""
    try:
        ans = json.loads(ans_raw)
    except (json.JSONDecodeError, TypeError):
        return str(ans_raw)

    if q_type == "single_choice":
        # ans 通常是 "A"
        label = str(ans)
        if label in option_map:
            return f"{label}. {option_map[label]}"
        return label

    if q_type == "multiple_choice":
        # ans 通常是 ["A", "C"]
        if isinstance(ans, list):
            parts = []
            for label in ans:
                label_str = str(label)
                if label_str in option_map:
                    parts.append(f"{label_str}. {option_map[label_str]}")
                else:
                    parts.append(label_str)
            return " | ".join(parts)
        return str(ans)

    if q_type == "true_false":
        if isinstance(ans, bool):
            return "正确" if ans else "错误"
        if str(ans).lower() in ("true", "1"):
            return "正确"
        if str(ans).lower() in ("false", "0"):
            return "错误"
        return str(ans)

    if q_type == "fill_blank":
        # ans 可能是 ["答案1", "答案2"] 对应多个空
        if isinstance(ans, list):
            return " | ".join(str(a) for a in ans)
        return str(ans)

    # short_answer 或其他
    return str(ans) if ans is not None else "(未作答)"


def _format_correct_answer(
    correct: Any, q_type: str, option_map: dict[str, str]
) -> str:
    """将正确答案 JSONB 值转为人类可读文本。"""
    if q_type == "single_choice":
        label = str(correct)
        if label in option_map:
            return f"{label}. {option_map[label]}"
        return label

    if q_type == "multiple_choice":
        if isinstance(correct, list):
            parts = []
            for label in correct:
                label_str = str(label)
                if label_str in option_map:
                    parts.append(f"{label_str}. {option_map[label_str]}")
                else:
                    parts.append(label_str)
            return " | ".join(parts)
        return str(correct)

    if q_type == "true_false":
        if isinstance(correct, bool):
            return "正确" if correct else "错误"
        return str(correct)

    if q_type == "fill_blank":
        if isinstance(correct, list):
            return " | ".join(str(a) for a in correct)
        return str(correct)

    # short_answer
    return json.dumps(correct, ensure_ascii=False, default=str) if correct is not None else "(无)"


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
        .select("id, question_type, content, correct_answer, score, options")
        .eq("id", question_id)
        .eq("assignment_id", assignment_id)
        .maybe_single()
        .execute()
    )
    if not question_result.data:
        raise ValueError("题目不存在")

    q = question_result.data
    q_type = q["question_type"]
    options: list[dict] | None = q.get("options")  # [{"label":"A","text":"..."},...]

    # 构建选项映射（仅选择题/判断题有意义）
    option_map: dict[str, str] = {}
    if options and isinstance(options, list):
        for opt in options:
            label = opt.get("label", "")
            text = opt.get("text", "")
            if label:
                option_map[label] = text

    # 获取该题全部作答，直接在服务端聚合，避免调用依赖 auth.uid() 的教师 RPC
    answers_result = await asyncio.to_thread(
        lambda: sb.table("student_answers")
        .select("answer, is_correct")
        .eq("question_id", question_id)
        .execute()
    )
    answer_rows: list[dict] = answers_result.data or []

    total_answers = len(answer_rows)
    wrong_answers = [row for row in answer_rows if row.get("is_correct") is False]
    wrong_count = len(wrong_answers)
    error_rate = round(wrong_count * 100.0 / total_answers, 1) if total_answers > 0 else 0

    # 聚合错误答案
    answer_counts: dict[str, int] = {}
    for wa in wrong_answers:
        key = json.dumps(wa.get("answer"), ensure_ascii=False, default=str)
        answer_counts[key] = answer_counts.get(key, 0) + 1

    sorted_answers = sorted(answer_counts.items(), key=lambda x: x[1], reverse=True)[:5]

    # 格式化错误答案——选择题附带选项文本
    wrong_lines: list[str] = []
    for ans_raw, cnt in sorted_answers:
        display = _format_answer_display(ans_raw, q_type, option_map)
        wrong_lines.append(f"  - {display}: {cnt}人")

    # 格式化正确答案
    correct_answer_str = _format_correct_answer(q["correct_answer"], q_type, option_map)

    # 构建选项段落
    options_section = ""
    if option_map and q_type in ("single_choice", "multiple_choice"):
        opt_lines = [f"  {label}. {text}" for label, text in sorted(option_map.items())]
        options_section = "- 选项:\n" + "\n".join(opt_lines) + "\n"

    prompt = _ERROR_ANALYSIS_PROMPT.format(
        question_type=_TYPE_LABELS.get(q_type, q_type),
        content=q["content"],
        options_section=options_section,
        correct_answer=correct_answer_str,
        error_rate=error_rate,
        total_answers=total_answers,
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
