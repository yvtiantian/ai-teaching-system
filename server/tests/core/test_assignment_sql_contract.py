from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
FILL_BLANK_FIX_SQL = REPO_ROOT / "supabase" / "migrations" / "20260405_fix_fill_blank_auto_grading_regression.sql"
STUDENT_REVIEW_STATUS_SQL = REPO_ROOT / "supabase" / "migrations" / "20260405_student_review_status_display_fix.sql"
UNANSWERED_FIX_SQL = REPO_ROOT / "supabase" / "migrations" / "20260406_fix_unanswered_submission_visibility.sql"


def test_student_submit_keeps_fill_blank_in_auto_grading_path() -> None:
    sql = FILL_BLANK_FIX_SQL.read_text(encoding="utf-8")

    assert "IF v_answer.question_type IN ('single_choice', 'multiple_choice', 'true_false', 'fill_blank') THEN" in sql
    assert "graded_by  = 'auto'" in sql


def test_student_submit_only_marks_short_answer_as_subjective() -> None:
    sql = FILL_BLANK_FIX_SQL.read_text(encoding="utf-8")

    assert "仅简答题等待后续 AI/教师复核" in sql
    assert "v_has_subjective := true;" in sql


def test_student_list_assignments_exposes_teacher_reviewed_flag() -> None:
    sql = STUDENT_REVIEW_STATUS_SQL.read_text(encoding="utf-8")

    assert "teacher_reviewed  BOOLEAN" in sql
    assert "sa.graded_by = 'teacher'" in sql


def test_student_get_result_returns_teacher_reviewed_flag() -> None:
    sql = STUDENT_REVIEW_STATUS_SQL.read_text(encoding="utf-8")

    assert "'teacher_reviewed',  EXISTS (" in sql
    assert "WHERE sa.submission_id = v_submission.id" in sql


def test_student_submit_grades_unanswered_questions_as_incorrect() -> None:
    sql = UNANSWERED_FIX_SQL.read_text(encoding="utf-8")

    assert "LEFT JOIN public.student_answers sa" in sql
    assert "IF NOT v_is_answered THEN" in sql
    assert "is_correct = false" in sql
    assert "score      = 0" in sql
    assert "主观题此时也不再进入 AI 评分" in sql


def test_teacher_and_admin_detail_include_unanswered_questions() -> None:
    sql = UNANSWERED_FIX_SQL.read_text(encoding="utf-8")

    assert "CREATE OR REPLACE FUNCTION public.teacher_get_submission_detail" in sql
    assert "WHERE aq.assignment_id = v_submission.assignment_id" in sql
    assert "CREATE OR REPLACE FUNCTION public.admin_get_submission_detail" in sql
    assert "WHERE q.assignment_id = (v_submission->>'assignment_id')::UUID" in sql

