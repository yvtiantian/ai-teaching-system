-- =====================================================
-- 模块 05_courses：触发器
-- =====================================================

-- 自动更新 courses.updated_at
DROP TRIGGER IF EXISTS trg_courses_updated_at ON public.courses;
CREATE TRIGGER trg_courses_updated_at
    BEFORE UPDATE ON public.courses
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 自动更新 course_enrollments.updated_at
DROP TRIGGER IF EXISTS trg_course_enrollments_updated_at ON public.course_enrollments;
CREATE TRIGGER trg_course_enrollments_updated_at
    BEFORE UPDATE ON public.course_enrollments
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
