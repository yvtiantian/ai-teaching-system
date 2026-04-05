-- ============================================================
-- Migration: 教师重新打开已关闭的作业
-- 生成日期: 2026-03-28
-- 说明: closed → published，若已超过截止日期则必须传入新截止时间
-- ============================================================

CREATE OR REPLACE FUNCTION public.teacher_reopen_assignment(
    p_assignment_id UUID,
    p_deadline TIMESTAMPTZ DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_new_deadline TIMESTAMPTZ;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权操作';
    END IF;

    IF v_assignment.status <> 'closed' THEN
        RAISE EXCEPTION '仅已关闭的作业可重新打开';
    END IF;

    -- 判断原截止时间是否已过期
    IF v_assignment.deadline IS NULL OR v_assignment.deadline <= now() THEN
        -- 已超过截止日期，必须提供新的截止时间
        IF p_deadline IS NULL THEN
            RAISE EXCEPTION '该作业已超过截止日期，重新打开时必须设置新的截止时间';
        END IF;
        IF p_deadline <= now() THEN
            RAISE EXCEPTION '截止日期必须在当前时间之后';
        END IF;
        v_new_deadline := p_deadline;
    ELSE
        -- 截止时间尚未到达（手动关闭），可以直接打开，也可选择更新截止时间
        IF p_deadline IS NOT NULL THEN
            IF p_deadline <= now() THEN
                RAISE EXCEPTION '截止日期必须在当前时间之后';
            END IF;
            v_new_deadline := p_deadline;
        ELSE
            v_new_deadline := v_assignment.deadline;
        END IF;
    END IF;

    UPDATE public.assignments SET
        status     = 'published',
        deadline   = v_new_deadline,
        updated_at = now()
    WHERE id = p_assignment_id AND teacher_id = v_uid;
END;
$$;

COMMENT ON FUNCTION public.teacher_reopen_assignment(UUID, TIMESTAMPTZ) IS '教师重新打开已关闭的作业（超过截止日期须设新截止时间）';
GRANT EXECUTE ON FUNCTION public.teacher_reopen_assignment(UUID, TIMESTAMPTZ) TO authenticated;
