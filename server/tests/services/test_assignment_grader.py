import asyncio

from src.services.assignment_grader import (
    _extract_short_answer_text,
    _grade_short_answer,
    _has_meaningful_short_answer,
)


def test_extract_short_answer_text_trims_whitespace() -> None:
    assert _extract_short_answer_text({"answer": "   你好  "}) == "你好"
    assert _extract_short_answer_text({"answer": "   "}) == ""
    assert _extract_short_answer_text({}) == ""


def test_has_meaningful_short_answer_rejects_blank_content() -> None:
    assert _has_meaningful_short_answer({"answer": "有效内容"}) is True
    assert _has_meaningful_short_answer({"answer": "   "}) is False
    assert _has_meaningful_short_answer(None) is False


def test_grade_short_answer_skips_blank_answer_without_ai() -> None:
    result = asyncio.run(
        _grade_short_answer(
            {"content": "简述概念", "correct_answer": {"answer": "参考答案"}, "score": 10},
            {"answer": {"answer": "   "}},
        )
    )

    assert result["score"] == 0
    assert result["is_correct"] is False
    assert result["ai_score"] is None
    assert result["ai_feedback"] is None
    assert result["graded_by"] == "auto"