"""AI 题目生成服务 — 调用 DeepSeek 根据参考资料生成结构化题目"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any

import httpx
from loguru import logger

from src.core.settings import settings
from src.core.supabase_client import get_supabase_client
from src.services.file_extractor import extract_text, supported_mime_types

# DeepSeek API
_DS_BASE = settings.deepseek.base_url.rstrip("/")
_DS_MODEL = settings.deepseek.resolved_chat_model
_DS_API_KEY = settings.deepseek.api_key
_DS_TIMEOUT = 120.0  # 生成可能较慢
_MAX_FILE_PATHS = 10  # 单次生成最多引用文件数
_ALLOWED_BUCKETS = {"assignment-materials"}  # 允许访问的 bucket 白名单

# 题型中文名映射
_TYPE_LABELS: dict[str, str] = {
    "single_choice": "单选题",
    "multiple_choice": "多选题",
    "fill_blank": "填空题",
    "true_false": "判断题",
    "short_answer": "简答题",
}

_EXAMPLE_BY_TYPE: dict[str, str] = {
        "single_choice": """    {
            \"question_type\": \"single_choice\",
            \"content\": \"题目正文\",
            \"options\": [{\"label\": \"A\", \"text\": \"选项内容\"}, {\"label\": \"B\", \"text\": \"...\"}, {\"label\": \"C\", \"text\": \"...\"}, {\"label\": \"D\", \"text\": \"...\"}],
            \"correct_answer\": {\"answer\": \"B\"},
            \"explanation\": \"答案解析\"
        }""",
        "multiple_choice": """    {
            \"question_type\": \"multiple_choice\",
            \"content\": \"题目正文\",
            \"options\": [{\"label\": \"A\", \"text\": \"...\"}, {\"label\": \"B\", \"text\": \"...\"}, {\"label\": \"C\", \"text\": \"...\"}, {\"label\": \"D\", \"text\": \"...\"}],
            \"correct_answer\": {\"answer\": [\"A\", \"C\"]},
            \"explanation\": \"答案解析\"
        }""",
        "fill_blank": """    {
            \"question_type\": \"fill_blank\",
            \"content\": \"____是Python的内置数据类型。\",
            \"options\": null,
            \"correct_answer\": {\"answer\": [\"dict\"], \"acceptable\": [\"字典\"]},
            \"explanation\": \"答案解析\"
        }""",
        "true_false": """    {
            \"question_type\": \"true_false\",
            \"content\": \"Python是编译型语言。\",
            \"options\": null,
            \"correct_answer\": {\"answer\": false},
            \"explanation\": \"答案解析\"
        }""",
        "short_answer": """    {
            \"question_type\": \"short_answer\",
            \"content\": \"简述Python中列表和元组的区别。\",
            \"options\": null,
            \"correct_answer\": {\"answer\": \"参考答案文本\"},
            \"explanation\": \"答案解析\"
        }""",
}

# ── Prompt 模板 ───────────────────────────────────────────

_SYSTEM_PROMPT = """\
你是一位专业的教学出题专家。请根据以下参考资料和要求，生成高质量的考试题目。
你必须严格按照指定的 JSON 格式输出，不要输出任何其他内容。"""

_USER_PROMPT_TEMPLATE = """\
【参考资料】
{file_contents}

【作业信息】
标题: {title}
{description_block}

【出题要求】
{requirements}

【题型约束】
{type_constraints}

【质量要求】
- 题目难度适中，覆盖参考资料的核心知识点
- 选项设计合理，干扰项具有迷惑性但不能有歧义
- 每道题附带答案解析
- 题目内容不可重复或过于相似

{custom_prompt}

【输出格式】
请输出严格的 JSON，格式如下:
{{
  "questions": [
{output_examples}
  ]
}}

注意:
- options 字段只有 single_choice 和 multiple_choice 需要，其他题型设为 null
- correct_answer 结构严格按照上面每种题型的示例
- 必须生成所有要求的题目数量"""


def _build_requirements(question_config: dict[str, Any]) -> str:
    """根据 question_config 构建出题要求文本。"""
    lines: list[str] = []
    for qtype, cfg in question_config.items():
        count = cfg.get("count", 0)
        if count <= 0:
            continue
        label = _TYPE_LABELS.get(qtype, qtype)
        if qtype == "single_choice":
            lines.append(f"- {label} {count} 道：每题4个选项，只有1个正确答案")
        elif qtype == "multiple_choice":
            lines.append(f"- {label} {count} 道：每题4-5个选项，2个及以上正确答案")
        elif qtype == "fill_blank":
            lines.append(f"- {label} {count} 道：每题1-2个空")
        elif qtype == "true_false":
            lines.append(f"- {label} {count} 道：判断对错")
        elif qtype == "short_answer":
            lines.append(f"- {label} {count} 道：需要简要分析作答")
    return "\n".join(lines) if lines else "（未指定题型要求）"


def _get_selected_types(question_config: dict[str, Any]) -> list[str]:
    selected = [
        qtype
        for qtype, cfg in question_config.items()
        if int((cfg or {}).get("count", 0)) > 0 and qtype in _EXAMPLE_BY_TYPE
    ]
    return selected or list(_EXAMPLE_BY_TYPE.keys())


def _build_type_constraints(question_config: dict[str, Any]) -> str:
    selected = _get_selected_types(question_config)
    type_labels = "、".join(_TYPE_LABELS[qtype] for qtype in selected)
    return "\n".join(
        [
            f"- 只允许输出以下题型: {type_labels}",
            "- 严禁输出未请求的题型",
            "- 每种题型的数量必须严格匹配出题要求",
        ]
    )


def _build_output_examples(question_config: dict[str, Any]) -> str:
    selected = _get_selected_types(question_config)
    return ",\n".join(_EXAMPLE_BY_TYPE[qtype] for qtype in selected)


async def _download_file(storage_path: str) -> tuple[bytes, str]:
    """从 Supabase Storage 下载文件，返回 (bytes, mime_type)。"""
    sb = get_supabase_client()
    # storage_path 格式: assignment-materials/{course_id}/{assignment_id}/{filename}
    # 也可能是 assignment-materials/{course_id}/temp/{uuid}/{filename}
    # 拆分 bucket 和 path
    parts = storage_path.split("/", 1)
    if len(parts) != 2:
        raise ValueError(f"无效的存储路径: {storage_path}")
    bucket_name, file_path = parts

    # B2: bucket 白名单校验，防止访问任意 bucket
    if bucket_name not in _ALLOWED_BUCKETS:
        raise ValueError(f"不允许访问的存储桶: {bucket_name}")

    # B1: supabase-py storage.download() 是同步的，包装到线程避免阻塞事件循环
    data = await asyncio.to_thread(sb.storage.from_(bucket_name).download, file_path)

    # 推断 MIME 类型
    lower = storage_path.lower()
    if lower.endswith(".pdf"):
        mime = "application/pdf"
    elif lower.endswith(".docx"):
        mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    elif lower.endswith(".pptx"):
        mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    else:
        mime = "text/plain"

    return data, mime


def _assign_scores(questions: list[dict], question_config: dict[str, Any]) -> list[dict]:
    """根据 question_config 中的 score_per_question 为每道题分配分值。"""
    score_map: dict[str, float] = {}
    for qtype, cfg in question_config.items():
        score_map[qtype] = cfg.get("score_per_question", 0)

    total = 0.0
    for i, q in enumerate(questions):
        qtype = q.get("question_type", "")
        score = score_map.get(qtype, 0)
        q["score"] = score
        q["sort_order"] = i + 1
        total += score

    return questions


def _validate_questions(questions: list[dict]) -> list[str]:
    """校验生成的题目结构，返回错误列表。"""
    errors: list[str] = []
    valid_types = set(_TYPE_LABELS.keys())

    for i, q in enumerate(questions, 1):
        qtype = q.get("question_type")
        if qtype not in valid_types:
            errors.append(f"题目 {i}: 无效题型 '{qtype}'")
            continue

        if not q.get("content"):
            errors.append(f"题目 {i}: 缺少题目内容")

        if qtype in ("single_choice", "multiple_choice"):
            opts = q.get("options")
            if not isinstance(opts, list) or len(opts) < 2:
                errors.append(f"题目 {i} ({qtype}): 选项数量不足")

        answer = q.get("correct_answer")
        if not isinstance(answer, dict) or "answer" not in answer:
            errors.append(f"题目 {i}: correct_answer 格式错误")

    return errors


def _validate_question_distribution(
    questions: list[dict], question_config: dict[str, Any]
) -> list[str]:
    """校验生成题目的题型分布是否与请求配置完全一致。"""
    errors: list[str] = []
    expected_counts = {
        qtype: int((cfg or {}).get("count", 0))
        for qtype, cfg in question_config.items()
        if int((cfg or {}).get("count", 0)) > 0
    }
    actual_counts: dict[str, int] = {}

    for question in questions:
        qtype = question.get("question_type")
        if not isinstance(qtype, str):
            continue
        actual_counts[qtype] = actual_counts.get(qtype, 0) + 1

    for qtype, expected in expected_counts.items():
        actual = actual_counts.get(qtype, 0)
        if actual != expected:
            label = _TYPE_LABELS.get(qtype, qtype)
            errors.append(f"题型分布不符合要求: {label} 期望 {expected} 道，实际 {actual} 道")

    for qtype, actual in actual_counts.items():
        if qtype not in expected_counts:
            label = _TYPE_LABELS.get(qtype, qtype)
            errors.append(f"题型分布不符合要求: 不应生成 {label}，但实际生成了 {actual} 道")

    return errors


async def generate_questions(
    *,
    title: str,
    description: str | None,
    file_paths: list[str],
    question_config: dict[str, Any],
    ai_prompt: str | None = None,
    max_retries: int = 2,
) -> dict[str, Any]:
    """生成题目主流程。

    Returns:
        {
            "questions": [...],
            "total_score": float,
            "generation_meta": {"model": str, "duration_ms": int}
        }
    """
    # B4: 限制文件数量
    if len(file_paths) > _MAX_FILE_PATHS:
        raise RuntimeError(f"参考文件数量不能超过 {_MAX_FILE_PATHS} 个")

    # 1. 下载并提取参考资料文本
    file_contents_parts: list[str] = []
    supported = set(supported_mime_types())

    for path in file_paths:
        try:
            data, mime = await _download_file(path)
            if mime not in supported:
                logger.warning("跳过不支持的文件类型: {} ({})", path, mime)
                continue
            text = extract_text(data, mime)
            if text.strip():
                file_contents_parts.append(f"--- 文件: {path.split('/')[-1]} ---\n{text}")
        except Exception as exc:
            logger.warning("文件下载/提取失败 {}: {}", path, exc)

    file_contents = "\n\n".join(file_contents_parts) if file_contents_parts else "（无参考资料）"

    # 2. 构建 prompt
    description_block = f"说明: {description}" if description else ""
    custom_prompt = f"【教师补充要求】\n{ai_prompt}" if ai_prompt else ""

    user_prompt = _USER_PROMPT_TEMPLATE.format(
        file_contents=file_contents,
        title=title,
        description_block=description_block,
        requirements=_build_requirements(question_config),
        type_constraints=_build_type_constraints(question_config),
        custom_prompt=custom_prompt,
        output_examples=_build_output_examples(question_config),
    )

    # 3. 调用 DeepSeek
    start_time = time.monotonic()
    questions = None
    last_error: str | None = None

    for attempt in range(1, max_retries + 1):
        try:
            raw = await _call_deepseek(user_prompt)
            parsed = _parse_response(raw)
            validation_errors = _validate_questions(parsed)
            validation_errors.extend(_validate_question_distribution(parsed, question_config))
            if validation_errors:
                last_error = "; ".join(validation_errors)
                logger.warning("生成校验失败 (尝试 {}/{}): {}", attempt, max_retries, last_error)
                if attempt < max_retries:
                    await asyncio.sleep(2 * attempt)  # B5: 退避延迟
                continue
            questions = parsed
            break
        except Exception as exc:
            last_error = str(exc)
            logger.warning("生成失败 (尝试 {}/{}): {}", attempt, max_retries, exc)
            if attempt < max_retries:
                await asyncio.sleep(2 * attempt)  # B5: 退避延迟

    if questions is None:
        raise RuntimeError(f"AI 题目生成失败（已重试 {max_retries} 次）: {last_error}")

    elapsed_ms = int((time.monotonic() - start_time) * 1000)

    # 4. 分配分值
    questions = _assign_scores(questions, question_config)
    total_score = sum(q.get("score", 0) for q in questions)

    return {
        "questions": questions,
        "total_score": total_score,
        "generation_meta": {
            "model": _DS_MODEL,
            "duration_ms": elapsed_ms,
        },
    }


async def _call_deepseek(user_prompt: str) -> str:
    """调用 DeepSeek chat API，使用 SSE 流式读取。"""
    payload = {
        "model": _DS_MODEL,
        "messages": [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt},
        ],
        "response_format": {"type": "json_object"},
        "stream": True,
        "temperature": 0.7,
        "max_tokens": 8192,
    }

    timeout = httpx.Timeout(connect=30.0, read=_DS_TIMEOUT, write=30.0, pool=30.0)
    content_parts: list[str] = []

    async with httpx.AsyncClient(timeout=timeout) as client:
        async with client.stream(
            "POST",
            f"{_DS_BASE}/v1/chat/completions",
            json=payload,
            headers={"Authorization": f"Bearer {_DS_API_KEY}"},
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data.strip() == "[DONE]":
                    break
                chunk = json.loads(data)
                delta = chunk.get("choices", [{}])[0].get("delta", {})
                token = delta.get("content", "")
                if token:
                    content_parts.append(token)

    content = "".join(content_parts)
    if not content:
        raise RuntimeError("DeepSeek 返回空内容")
    return content


def _clean_literal_newlines(obj: Any) -> Any:
    """递归清理所有字符串中的字面 \\n 为真正的换行符。

    DeepSeek 有时会在 JSON 中生成双转义 \\\\n，经 json.loads 后会残留字面 \\n。
    """
    if isinstance(obj, str):
        return obj.replace("\\n", "\n")
    if isinstance(obj, list):
        return [_clean_literal_newlines(item) for item in obj]
    if isinstance(obj, dict):
        return {k: _clean_literal_newlines(v) for k, v in obj.items()}
    return obj


def _parse_response(raw: str) -> list[dict]:
    """解析 DeepSeek 返回的 JSON 字符串，提取 questions 列表。"""
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"JSON 解析失败: {exc}") from exc

    # 清理 LLM 可能产生的字面 \n
    obj = _clean_literal_newlines(obj)

    # 兼容直接返回列表或包裹在 { "questions": [...] } 中
    if isinstance(obj, list):
        return obj
    if isinstance(obj, dict):
        questions = obj.get("questions")
        if isinstance(questions, list):
            return questions
    raise RuntimeError(f"无法从响应中提取题目列表，响应结构: {type(obj)}")
