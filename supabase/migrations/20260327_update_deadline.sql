-- 新增：教师修改已发布作业的截止时间
CREATE OR REPLACE FUNCTION public.teacher_update_deadline(
    p_assignment_id UUID,
    p_deadline TIMESTAMPTZ
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := public._assert_teacher();

    IF p_deadline IS NULL OR p_deadline <= now() THEN
        RAISE EXCEPTION '截止日期不能为空且必须是将来的时间';
    END IF;

    UPDATE public.assignments SET
        deadline   = p_deadline,
        updated_at = now()
    WHERE id = p_assignment_id AND teacher_id = v_uid AND status = 'published';

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在、无权操作或非已发布状态';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_update_deadline(UUID, TIMESTAMPTZ) IS '教师修改已发布作业的截止时间';
GRANT EXECUTE ON FUNCTION public.teacher_update_deadline(UUID, TIMESTAMPTZ) TO authenticated;
