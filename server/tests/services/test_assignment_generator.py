from src.services.assignment_generator import _build_output_examples


def test_build_output_examples_only_includes_selected_type() -> None:
    examples = _build_output_examples(
        {
            "fill_blank": {"count": 5, "score_per_question": 2},
        }
    )

    assert '"question_type": "fill_blank"' in examples
    assert '"question_type": "single_choice"' not in examples
    assert '"question_type": "multiple_choice"' not in examples
    assert '"question_type": "true_false"' not in examples
    assert '"question_type": "short_answer"' not in examples


def test_build_output_examples_supports_multiple_selected_types() -> None:
    examples = _build_output_examples(
        {
            "single_choice": {"count": 3, "score_per_question": 2},
            "fill_blank": {"count": 2, "score_per_question": 3},
            "short_answer": {"count": 1, "score_per_question": 10},
        }
    )

    assert '"question_type": "single_choice"' in examples
    assert '"question_type": "fill_blank"' in examples
    assert '"question_type": "short_answer"' in examples
    assert '"question_type": "multiple_choice"' not in examples
    assert '"question_type": "true_false"' not in examples