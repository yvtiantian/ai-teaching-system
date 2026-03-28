"""DeepSeek 标题生成服务

通过 OpenAI 兼容 API 调用 DeepSeek 生成对话标题。
"""

import httpx
from loguru import logger

from src.core.settings import settings

_TITLE_PROMPT = """你是一个标题生成助手。根据以下对话内容，生成一个简短的中文标题（5-15个字）。
只输出标题本身，不要加引号、不要加解释。

对话内容：
{messages}

标题："""


async def generate_title(messages: list[dict]) -> str:
    """根据对话消息列表生成标题"""
    if not messages:
        return "新会话"

    # 格式化最近几条消息
    formatted = []
    for msg in messages[-5:]:
        role = msg.get("role", "unknown")
        content = msg.get("content", "")
        if content:
            formatted.append(f"{role}: {content[:200]}")

    if not formatted:
        return "新会话"

    prompt = _TITLE_PROMPT.format(messages="\n".join(formatted))

    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(
                f"{settings.deepseek.base_url}/v1/chat/completions",
                headers={"Authorization": f"Bearer {settings.deepseek.api_key}"},
                json={
                    "model": settings.deepseek.resolved_title_model,
                    "messages": [{"role": "user", "content": prompt}],
                    "temperature": 0.3,
                    "max_tokens": 30,
                },
            )
            resp.raise_for_status()
            title = resp.json()["choices"][0]["message"]["content"].strip()

            # 清理：移除引号、换行等
            title = title.strip('"\'""「」').split("\n")[0].strip()
            if len(title) >= 2:
                return title[:30]

    except Exception as e:
        logger.warning(f"标题生成失败: {e}")

    return "新会话"
