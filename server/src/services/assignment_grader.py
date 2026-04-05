"""AI 作业批改服务 — 仅调用 Ollama 对简答题进行 AI 评分"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any

import httpx
from loguru import logger

from src.core.settings import settings
from src.core.supabase_client import get_supabase_client

# ── Ollama 配置 ──────────────────────────────────────────

_OLLAMA_BASE = settings.ollama.base_url.rstrip("/")
_OLLAMA_MODEL = settings.ollama.model
_OLLAMA_TIMEOUT = settings.ollama.timeout_per_question
_JOB_TIMEOUT = settings.ollama.job_timeout

# ── Prompt 模板 ──────────────────────────────────────────

_SHORT_ANSWER_PROMPT = """\
你是一位专业的教学评估助手。请根据参考答案对学生的简答题进行评分。

题目内容: {content}
参考答案: {correct_answer}
学生答案: {student_answer}
满分: {max_score}

评分维度：
1. 核心知识点覆盖度（40%）：是否涵盖参考答案中的关键概念
2. 表述准确性（30%）：专业术语使用是否恰当
3. 逻辑完整性（20%）：论述是否有条理
4. 语言规范性（10%）：表达是否清晰流畅

以 JSON 格式返回：
{{
  "score": 数字（0 到 {max_score}，支持小数，保留1位）,
  "breakdown": {{
    "knowledge_coverage": {{ "score": 数字, "max": 数字, "comment": "..." }},
    "accuracy": {{ "score": 数字, "max": 数字, "comment": "..." }},
    "logic": {{ "score": 数字, "max": 数字, "comment": "..." }},
    "language": {{ "score": 数字, "max": 数字, "comment": "..." }}
  }},
  "feedback": "整体评语（100-200字）",
  "highlights": "答得好的地方",
  "improvements": "需要改进的地方"
}}"""

# ── 题型中文名 ────────────────────────────────────────────

_TYPE_LABELS: dict[str, str] = {
    "single_choice": "单选题",
    "multiple_choice": "多选题",
    "true_false": "判断题",
    "fill_blank": "填空题",
    "short_answer": "简答题",
}


# ══════════════════════════════════════════════════════════
# 公共入口
# ══════════════════════════════════════════════════════════

async def grade_submission(submission_id: str) -> dict[str, Any]:
    """对一份提交进行完整 AI 批改（阶段二）。

    流程：
    1. 从 DB 加载 submission + questions + student_answers
    2. 将 status 设为 ai_grading
    3. 逐题调用 Ollama 生成反馈 / 评分
    4. 写回每题的 ai_score / ai_feedback / ai_detail
    5. 汇总分数，将 status 设为 ai_graded
    """
    start = time.monotonic()
    sb = get_supabase_client()

    # 1. 加载数据
    submission = await _load_submission(sb, submission_id)
    if not submission:
        raise RuntimeError(f"提交记录不存在: {submission_id}")

    if submission["status"] not in ("submitted", "ai_grading"):
        raise RuntimeError(f"提交状态不允许批改: {submission['status']}")

    questions = await _load_questions(sb, submission["assignment_id"])
    answers = await _load_answers(sb, submission_id)

    if not answers:
        raise RuntimeError("没有学生答案")

    # 建立 question_id → question 映射
    q_map: dict[str, dict] = {str(q["id"]): q for q in questions}

    # 2. 标记 ai_grading
    await _update_submission_status(sb, submission_id, "ai_grading")

    # 3. 逐题 AI 批改
    total_ai_score = 0.0
    graded_count = 0
    failed_count = 0

    for ans in answers:
        qid = str(ans["question_id"])
        question = q_map.get(qid)
        if not question:
            logger.warning("答案对应的题目不存在: qid={}", qid)
            continue

        # 仅简答题需要 AI 批改，其他题型已由 SQL 自动评分
        if question["question_type"] != "short_answer":
            continue

        try:
            result = await asyncio.wait_for(
                _grade_short_answer(question, ans),
                timeout=_OLLAMA_TIMEOUT,
            )
            await _save_answer_result(sb, str(ans["id"]), result)
            total_ai_score += result.get("score", 0)
            graded_count += 1
        except asyncio.TimeoutError:
            logger.warning("题目 AI 批改超时: qid={}", qid)
            fallback = _fallback_result(question, ans)
            await _save_answer_result(sb, str(ans["id"]), fallback)
            total_ai_score += fallback.get("score", 0)
            failed_count += 1
        except Exception as exc:
            logger.error("题目 AI 批改失败: qid={}, error={}", qid, exc)
            fallback = _fallback_result(question, ans)
            await _save_answer_result(sb, str(ans["id"]), fallback)
            total_ai_score += fallback.get("score", 0)
            failed_count += 1

    # 4. 汇总：auto_score（客观题 SQL 已算）+ ai_score（主观题 AI 评分）
    # 重新查一次所有答案最终 score 汇总
    final_answers = await _load_answers(sb, submission_id)
    final_total = sum(float(a.get("score") or 0) for a in final_answers)

    await _finalize_submission(sb, submission_id, final_total)

    elapsed_ms = int((time.monotonic() - start) * 1000)
    logger.info(
        "AI 批改完成: submission={}, graded={}, failed={}, total_score={}, elapsed={}ms",
        submission_id,
        graded_count,
        failed_count,
        final_total,
        elapsed_ms,
    )

    return {
        "submission_id": submission_id,
        "graded_count": graded_count,
        "failed_count": failed_count,
        "total_score": final_total,
        "elapsed_ms": elapsed_ms,
    }


# ══════════════════════════════════════════════════════════
# 简答题 AI 评分
# ══════════════════════════════════════════════════════════

async def _grade_short_answer(
    question: dict[str, Any],
    answer: dict[str, Any],
) -> dict[str, Any]:
    """简答题：调用 AI 按 4 维度评分。"""
    correct = question.get("correct_answer") or {}
    correct_answer = correct.get("answer", "")
    student_ans = (answer.get("answer") or {})
    student_answer = student_ans.get("answer", "") if isinstance(student_ans, dict) else ""
    max_score = float(question.get("score", 0))

    if not student_answer or not str(student_answer).strip():
        return {
            "score": 0,
            "is_correct": False,
            "ai_score": 0,
            "ai_feedback": "未作答",
            "ai_detail": None,
            "graded_by": "ai",
        }

    prompt = _SHORT_ANSWER_PROMPT.format(
        content=question["content"],
        correct_answer=correct_answer,
        student_answer=student_answer,
        max_score=max_score,
    )

    raw = await _call_ollama(prompt, json_mode=True)
    parsed = _parse_json(raw)

    if parsed:
        score = min(float(parsed.get("score", 0)), max_score)
        score = max(score, 0)
        return {
            "score": round(score, 1),
            "is_correct": score >= max_score * 0.6,
            "ai_score": round(score, 1),
            "ai_feedback": parsed.get("feedback", ""),
            "ai_detail": {
                "breakdown": parsed.get("breakdown"),
                "highlights": parsed.get("highlights"),
                "improvements": parsed.get("improvements"),
            },
            "graded_by": "ai",
        }

    # JSON 解析失败 → fallback
    return {
        "score": 0,
        "is_correct": None,
        "ai_score": 0,
        "ai_feedback": "AI 批改失败，请教师手动评分",
        "ai_detail": None,
        "graded_by": "fallback",
    }


# ══════════════════════════════════════════════════════════
# Fallback 策略
# ══════════════════════════════════════════════════════════

def _fallback_result(question: dict, answer: dict) -> dict[str, Any]:
    """简答题 AI 批改失败时的兜底。"""
    return {
        "score": 0,
        "is_correct": None,
        "ai_score": 0,
        "ai_feedback": "AI 批改失败，请教师手动评分",
        "ai_detail": None,
        "graded_by": "fallback",
    }


# ══════════════════════════════════════════════════════════
# Ollama 调用
# ══════════════════════════════════════════════════════════

async def _call_ollama(prompt: str, *, json_mode: bool = False) -> str:
    """调用 Ollama OpenAI-compatible API，流式读取。"""
    payload: dict[str, Any] = {
        "model": _OLLAMA_MODEL,
        "messages": [
            {"role": "user", "content": prompt},
        ],
        "stream": True,
        "temperature": 0.3,
    }
    if json_mode:
        payload["response_format"] = {"type": "json_object"}

    timeout = httpx.Timeout(connect=30.0, read=float(_OLLAMA_TIMEOUT), write=30.0, pool=30.0)
    content_parts: list[str] = []

    async with httpx.AsyncClient(timeout=timeout) as client:
        async with client.stream(
            "POST",
            f"{_OLLAMA_BASE}/v1/chat/completions",
            json=payload,
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
                    delta = chunk.get("choices", [{}])[0].get("delta", {})
                    token = delta.get("content", "")
                    if token:
                        content_parts.append(token)
                except json.JSONDecodeError:
                    continue

    content = "".join(content_parts)
    if not content:
        raise RuntimeError("Ollama 返回空内容")
    return content


def _parse_json(raw: str) -> dict[str, Any] | None:
    """尝试解析 JSON，失败返回 None。"""
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj
    except json.JSONDecodeError:
        # 尝试提取 JSON 块
        start = raw.find("{")
        end = raw.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                return json.loads(raw[start:end])
            except json.JSONDecodeError:
                pass
    logger.warning("JSON 解析失败: {}", raw[:200])
    return None


# ══════════════════════════════════════════════════════════
# DB 操作（使用 service_key 绕过 RLS）
# ══════════════════════════════════════════════════════════

async def _load_submission(sb: Any, submission_id: str) -> dict | None:
    result = await asyncio.to_thread(
        lambda: sb.table("assignment_submissions")
        .select("id, assignment_id, student_id, status, total_score")
        .eq("id", submission_id)
        .maybe_single()
        .execute()
    )
    return result.data


async def _load_questions(sb: Any, assignment_id: str) -> list[dict]:
    result = await asyncio.to_thread(
        lambda: sb.table("assignment_questions")
        .select("id, question_type, content, options, correct_answer, score, sort_order")
        .eq("assignment_id", assignment_id)
        .order("sort_order")
        .execute()
    )
    return result.data or []


async def _load_answers(sb: Any, submission_id: str) -> list[dict]:
    result = await asyncio.to_thread(
        lambda: sb.table("student_answers")
        .select("id, submission_id, question_id, answer, is_correct, score, graded_by")
        .eq("submission_id", submission_id)
        .execute()
    )
    return result.data or []


async def _save_answer_result(sb: Any, answer_id: str, result: dict) -> None:
    update_data: dict[str, Any] = {"updated_at": "now()"}
    for key in ("score", "is_correct", "ai_score", "ai_feedback", "ai_detail", "graded_by"):
        if key in result:
            update_data[key] = result[key]

    await asyncio.to_thread(
        lambda: sb.table("student_answers")
        .update(update_data)
        .eq("id", answer_id)
        .execute()
    )


async def _update_submission_status(sb: Any, submission_id: str, status: str) -> None:
    await asyncio.to_thread(
        lambda: sb.table("assignment_submissions")
        .update({"status": status, "updated_at": "now()"})
        .eq("id", submission_id)
        .execute()
    )


async def _finalize_submission(sb: Any, submission_id: str, total_score: float) -> None:
    await asyncio.to_thread(
        lambda: sb.table("assignment_submissions")
        .update({
            "status": "ai_graded",
            "total_score": total_score,
            "updated_at": "now()",
        })
        .eq("id", submission_id)
        .execute()
    )
