"""Analytics API — 错因分析端点"""

import json

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from loguru import logger
from pydantic import BaseModel

from src.services.learning_analytics import (
    load_error_analysis_context,
    stream_error_analysis,
)

router = APIRouter(prefix="/api/analytics", tags=["analytics"])


# ── 认证依赖 ────────────────────────────────────────────────

async def _get_current_user_id(request: Request) -> str:
    user_id = getattr(request.state, "user_id", None)
    if user_id:
        return str(user_id)
    user = getattr(request.state, "user", None)
    if isinstance(user, dict):
        uid = user.get("sub") or user.get("user_id") or user.get("id")
        if uid:
            return str(uid)
    raise HTTPException(status_code=401, detail="Not authenticated")


# ── 请求模型 ────────────────────────────────────────────────

class ErrorAnalysisRequest(BaseModel):
    assignment_id: str
    question_id: str


# ── 端点 ────────────────────────────────────────────────────

@router.post("/error-analysis")
async def error_analysis_endpoint(
    body: ErrorAnalysisRequest,
    user_id: str = Depends(_get_current_user_id),
):
    """对高错误率题目进行 AI 错因分析（SSE 流式）。"""
    try:
        context = await load_error_analysis_context(
            assignment_id=body.assignment_id,
            question_id=body.question_id,
            teacher_id=user_id,
        )
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except Exception as exc:
        logger.exception("加载 AI 错因分析上下文失败: {}", exc)
        raise HTTPException(status_code=500, detail="加载 AI 错因分析上下文失败")

    async def event_stream():
        try:
            async for token in stream_error_analysis(context):
                yield f"data: {json.dumps({'content': token}, ensure_ascii=False)}\n\n"
            yield "data: [DONE]\n\n"
        except Exception as exc:
            logger.error("AI 错因分析异常: {}", exc)
            yield f"data: {json.dumps({'error': 'AI 分析异常，请稍后重试'}, ensure_ascii=False)}\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")
