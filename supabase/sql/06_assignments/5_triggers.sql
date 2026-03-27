-- =====================================================
-- 模块 06_assignments：触发器
-- =====================================================

-- 自动更新 assignments.updated_at
DROP TRIGGER IF EXISTS trg_assignments_updated_at ON public.assignments;
CREATE TRIGGER trg_assignments_updated_at
    BEFORE UPDATE ON public.assignments
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 自动更新 assignment_questions.updated_at
DROP TRIGGER IF EXISTS trg_assignment_questions_updated_at ON public.assignment_questions;
CREATE TRIGGER trg_assignment_questions_updated_at
    BEFORE UPDATE ON public.assignment_questions
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 自动更新 assignment_files.updated_at
DROP TRIGGER IF EXISTS trg_assignment_files_updated_at ON public.assignment_files;
CREATE TRIGGER trg_assignment_files_updated_at
    BEFORE UPDATE ON public.assignment_files
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 自动更新 assignment_submissions.updated_at
DROP TRIGGER IF EXISTS trg_assignment_submissions_updated_at ON public.assignment_submissions;
CREATE TRIGGER trg_assignment_submissions_updated_at
    BEFORE UPDATE ON public.assignment_submissions
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
