"""Assignments API — AI 题目生成端点"""

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from src.core.supabase_client import get_supabase_client
from src.services.assignment_generator import generate_questions

router = APIRouter(prefix="/api/assignments", tags=["assignments"])


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


# ── 请求/响应模型 ───────────────────────────────────────────

class QuestionTypeConfig(BaseModel):
    count: int = Field(ge=0, default=0)
    score_per_question: float = Field(ge=0, default=0)


class GenerateRequest(BaseModel):
    course_id: str
    title: str = Field(min_length=1, max_length=200)
    description: str | None = None
    file_paths: list[str] = Field(default_factory=list, max_length=10)
    question_config: dict[str, QuestionTypeConfig]
    ai_prompt: str | None = None


# ── 端点 ────────────────────────────────────────────────────

async def _verify_course_teacher(course_id: str, user_id: str) -> None:
    """B3: 验证当前用户是该课程的教师，防止越权。"""
    import asyncio

    sb = get_supabase_client()
    result = await asyncio.to_thread(
        lambda: sb.table("courses")
        .select("id")
        .eq("id", course_id)
        .eq("teacher_id", user_id)
        .maybe_single()
        .execute()
    )
    if not result.data:
        raise HTTPException(status_code=403, detail="无权操作此课程")


@router.post("/generate")
async def generate_assignment_questions(
    body: GenerateRequest,
    user_id: str = Depends(_get_current_user_id),
):
    """根据参考资料和配置，调用 AI 生成题目。"""
    # B3: 验证课程归属
    await _verify_course_teacher(body.course_id, user_id)

    # 至少配置一种题型且数量 > 0
    total_count = sum(cfg.count for cfg in body.question_config.values())
    if total_count == 0:
        raise HTTPException(status_code=400, detail="至少需要配置一种题型且数量大于0")

    # 转为 dict 传给 service
    config_dict = {k: v.model_dump() for k, v in body.question_config.items()}

    try:
        result = await generate_questions(
            title=body.title,
            description=body.description,
            file_paths=body.file_paths,
            question_config=config_dict,
            ai_prompt=body.ai_prompt,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc))

    return result
