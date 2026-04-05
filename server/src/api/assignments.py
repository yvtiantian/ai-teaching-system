"""Assignments API — AI 题目生成 & AI 批改端点"""

import asyncio

from fastapi import APIRouter, Depends, HTTPException, Request
from loguru import logger
from pydantic import BaseModel, Field

from src.core.supabase_client import get_supabase_client
from src.services.assignment_generator import generate_questions
from src.services.assignment_grader import grade_submission

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


# ── AI 批改 ─────────────────────────────────────────────

class GradeRequest(BaseModel):
    submission_id: str


@router.post("/grade")
async def grade_submission_endpoint(
    body: GradeRequest,
    user_id: str = Depends(_get_current_user_id),
):
    """触发 AI 异步批改。\n\n
    前端在 student_submit() 返回 has_subjective=true 后调用此接口。
    批改以 asyncio background task 运行，接口立即返回。
    """
    # 校验 submission 存在且归属当前用户
    import asyncio as _aio

    sb = get_supabase_client()
    result = await _aio.to_thread(
        lambda: sb.table("assignment_submissions")
        .select("id, student_id, status")
        .eq("id", body.submission_id)
        .maybe_single()
        .execute()
    )
    if not result.data:
        raise HTTPException(status_code=404, detail="提交记录不存在")

    sub = result.data
    if sub["student_id"] != user_id:
        raise HTTPException(status_code=403, detail="无权操作此提交")

    if sub["status"] not in ("submitted", "ai_grading"):
        raise HTTPException(status_code=400, detail="当前状态不允许批改")

    # 后台异步执行 AI 批改
    asyncio.create_task(_run_grading(body.submission_id))

    return {"message": "AI 批改已启动", "submission_id": body.submission_id}


async def _run_grading(submission_id: str) -> None:
    """后台 AI 批改任务，捕获所有异常避免 unhandled error。"""
    try:
        result = await grade_submission(submission_id)
        logger.info("AI 批改完成: {}", result)
    except Exception as exc:
        logger.error("AI 批改异常: submission={}, error={}", submission_id, exc)
        # 即使失败也标记为 ai_graded，让教师可以手动处理
        try:
            sb = get_supabase_client()
            await asyncio.to_thread(
                lambda: sb.table("assignment_submissions")
                .update({"status": "ai_graded", "updated_at": "now()"})
                .eq("id", submission_id)
                .execute()
            )
        except Exception:
            logger.error("标记 ai_graded 也失败: submission={}", submission_id)
