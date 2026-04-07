from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
FILL_BLANK_FIX_SQL = REPO_ROOT / "supabase" / "migrations" / "20260405_fix_fill_blank_auto_grading_regression.sql"
STUDENT_REVIEW_STATUS_SQL = REPO_ROOT / "supabase" / "migrations" / "20260405_student_review_status_display_fix.sql"
UNANSWERED_FIX_SQL = REPO_ROOT / "supabase" / "migrations" / "20260406_fix_unanswered_submission_visibility.sql"
AUTO_GRADED_STATUS_SQL = REPO_ROOT / "supabase" / "migrations" / "20260406_add_auto_graded_status.sql"
PENDING_SHORT_ANSWER_RESULT_SQL = REPO_ROOT / "supabase" / "migrations" / "20260406_fix_pending_short_answer_result_status.sql"
TEACHER_SUBMISSION_TOTAL_SQL = REPO_ROOT / "supabase" / "migrations" / "20260406_teacher_submission_list_show_total_score.sql"


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


def test_student_get_result_keeps_pending_short_answer_unjudged() -> None:
    sql = PENDING_SHORT_ANSWER_RESULT_SQL.read_text(encoding="utf-8")

    assert "v_submission.status IN ('submitted', 'ai_grading')" in sql
    assert "COALESCE(sa.graded_by, 'pending') = 'pending'" in sql
    assert "THEN NULL" in sql
    assert "WHEN sa.id IS NULL THEN false" in sql


def test_assignment_submissions_status_supports_auto_graded() -> None:
    sql = AUTO_GRADED_STATUS_SQL.read_text(encoding="utf-8")

    assert "CHECK (status IN ('not_started', 'in_progress', 'submitted', 'ai_grading', 'auto_graded', 'ai_graded', 'graded'))" in sql


def test_student_submit_routes_reviewable_auto_scoring_to_auto_graded() -> None:
    sql = AUTO_GRADED_STATUS_SQL.read_text(encoding="utf-8")

    assert "v_has_reviewable_auto BOOLEAN := false;" in sql
    assert "v_answer.question_type IN ('fill_blank', 'short_answer')" in sql
    assert "ELSIF v_has_reviewable_auto THEN" in sql
    assert "status       = 'auto_graded'" in sql


def test_teacher_finalize_grading_accepts_auto_graded() -> None:
    sql = AUTO_GRADED_STATUS_SQL.read_text(encoding="utf-8")

    assert "IF v_submission.status NOT IN ('submitted', 'auto_graded', 'ai_graded') THEN" in sql


def test_teacher_and_admin_stats_split_auto_graded_and_ai_graded() -> None:
    sql = AUTO_GRADED_STATUS_SQL.read_text(encoding="utf-8")

    assert "'auto_graded_count',   v_auto_graded" in sql
    assert "status IN ('submitted', 'ai_grading', 'auto_graded', 'ai_graded', 'graded')" in sql
    assert "'auto_graded_count',  COALESCE(SUM(CASE WHEN s.status = 'auto_graded' THEN 1 END), 0)" in sql


def test_teacher_list_submissions_returns_assignment_total_score() -> None:
    sql = TEACHER_SUBMISSION_TOTAL_SQL.read_text(encoding="utf-8")

    assert "'assignment_total_score', v_assignment.total_score" in sql
    assert "'total_score',            sub.total_score" in sql

