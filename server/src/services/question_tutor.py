"""题目 AI 解惑辅导服务 — 学生针对已批改题目与 AI 进行一对一辅导对话"""

from __future__ import annotations

import asyncio
import json
from typing import Any, AsyncIterator

import httpx
from loguru import logger

from src.core.settings import settings
from src.core.supabase_client import get_supabase_client

# ── DeepSeek 配置 ──────────────────────────────────────────

_DEEPSEEK_BASE = settings.deepseek.base_url.rstrip("/")
_DEEPSEEK_MODEL = settings.deepseek.default_model
_DEEPSEEK_API_KEY = settings.deepseek.api_key
_TUTOR_TIMEOUT = 60
_MAX_ROUNDS = 20

# ── 题型中文标签 ────────────────────────────────────────────

_TYPE_LABELS: dict[str, str] = {
    "single_choice": "单选题",
    "multiple_choice": "多选题",
    "true_false": "判断题",
    "fill_blank": "填空题",
    "short_answer": "简答题",
}

# ── System Prompt 模板 ──────────────────────────────────────

_SYSTEM_PROMPT = """\
你是一位耐心的学习辅导老师。学生正在回顾已批改的作业题目，请基于以下题目信息帮助学生理解。

## 题目信息
- 题型：{question_type}
- 题目内容：{content}
{options_section}- 满分：{max_score}
- 学生答案：{student_answer}
- 正确答案：{correct_answer}
- 学生得分：{score}/{max_score}
- 参考解析：{explanation}
- 批改反馈：{feedback}

## 辅导要求
1. 使用苏格拉底式引导，优先启发学生思考，而不是直接给出完整答案
2. 回答简洁明了，每次回复控制在 300 字以内
3. 仅讨论本题及关联知识点，拒绝回答与本题无关的问题
4. 如果学生尝试让你帮忙做其他作业或题目，礼貌拒绝并引导回本题
5. 使用 Markdown 格式化回复"""


# ══════════════════════════════════════════════════════════
# 权限校验 + 上下文加载
# ══════════════════════════════════════════════════════════

async def load_question_context(
    question_id: str,
    submission_id: str,
    student_id: str,
) -> dict[str, Any]:
    """从数据库加载题目上下文，同时校验学生访问权限。

    Returns:
        包含题目和学生答题信息的字典

    Raises:
        PermissionError: 无权访问
        ValueError: 数据不存在或状态不允许
    """
    sb = get_supabase_client()

    # 1. 校验 submission 归属 + 状态
    sub = await asyncio.to_thread(
        lambda: sb.table("assignment_submissions")
        .select("id, student_id, status, assignment_id")
        .eq("id", submission_id)
        .maybe_single()
        .execute()
    )
    if not sub.data:
        raise ValueError("提交记录不存在")
    if sub.data["student_id"] != student_id:
        raise PermissionError("无权访问此提交")
    if sub.data["status"] not in ("graded", "auto_graded"):
        raise ValueError("作业尚未完成评分，暂不可用")

    # 2. 加载题目信息
    question = await asyncio.to_thread(
        lambda: sb.table("assignment_questions")
        .select("id, content, question_type, options, correct_answer, explanation, score")
        .eq("id", question_id)
        .eq("assignment_id", sub.data["assignment_id"])
        .maybe_single()
        .execute()
    )
    if not question.data:
        raise ValueError("题目不存在")

    # 3. 加载学生答案
    answer = await asyncio.to_thread(
        lambda: sb.table("student_answers")
        .select("answer, score, ai_feedback, teacher_comment")
        .eq("submission_id", submission_id)
        .eq("question_id", question_id)
        .maybe_single()
        .execute()
    )

    q = question.data
    a = answer.data or {}

    # 构建选项映射（选择题用）
    options = q.get("options") or []
    option_map: dict[str, str] = {}
    if isinstance(options, list):
        for opt in options:
            if isinstance(opt, dict) and "label" in opt and "text" in opt:
                option_map[opt["label"]] = opt["text"]

    # 生成选项文本段落
    if option_map:
        options_lines = "\n".join(f"  {label}. {text}" for label, text in option_map.items())
        options_section = f"- 选项：\n{options_lines}\n"
    else:
        options_section = ""

    return {
        "question_type": _TYPE_LABELS.get(q["question_type"], q["question_type"]),
        "content": q["content"],
        "options_section": options_section,
        "max_score": q["score"],
        "correct_answer": _format_answer(q.get("correct_answer")),
        "explanation": q.get("explanation") or "无",
        "student_answer": _format_answer(a.get("answer")),
        "score": a.get("score", 0),
        "feedback": a.get("ai_feedback") or a.get("teacher_comment") or "无",
    }


def _format_answer(answer: Any) -> str:
    """将答案对象格式化为可读字符串。选择题仅保留选项标签，选项文本单独放在上下文中。"""
    if answer is None:
        return "（未作答）"

    if isinstance(answer, dict):
        val = answer.get("answer")
        if val is None:
            return "（未作答）"
        if isinstance(val, list):
            return ", ".join(str(v) for v in val)
        if isinstance(val, bool):
            return "正确" if val else "错误"
        return str(val)
    return str(answer)


# ══════════════════════════════════════════════════════════
# 流式对话
# ══════════════════════════════════════════════════════════

async def stream_tutor_chat(
    context: dict[str, Any],
    messages: list[dict[str, str]],
) -> AsyncIterator[str]:
    """用题目上下文 + 对话历史调用 DeepSeek，流式 yield 文本 token。"""
    system_prompt = _SYSTEM_PROMPT.format(**context)

    api_messages = [{"role": "system", "content": system_prompt}]
    for msg in messages[-_MAX_ROUNDS * 2:]:  # 保留最近对话
        api_messages.append({
            "role": msg["role"],
            "content": msg["content"],
        })

    payload = {
        "model": _DEEPSEEK_MODEL,
        "messages": api_messages,
        "stream": True,
        "temperature": 0.6,
    }

    headers = {
        "Authorization": f"Bearer {_DEEPSEEK_API_KEY}",
        "Content-Type": "application/json",
    }

    timeout = httpx.Timeout(connect=30.0, read=float(_TUTOR_TIMEOUT), write=30.0, pool=30.0)

    async with httpx.AsyncClient(timeout=timeout) as client:
        async with client.stream(
            "POST",
            f"{_DEEPSEEK_BASE}/chat/completions",
            json=payload,
            headers=headers,
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data.strip() == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                    token = chunk.get("choices", [{}])[0].get("delta", {}).get("content", "")
                    if token:
                        yield token
                except json.JSONDecodeError:
                    continue
