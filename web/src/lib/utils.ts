import dayjs from "dayjs";
import type { QuestionType } from "@/types/assignment";

export function toErrorMessage(error: unknown, fallback = "操作失败") {
  if (error instanceof Error) return error.message;
  return fallback;
}

export function formatDateTime(value: string | null) {
  if (!value) return "-";
  const parsed = dayjs(value);
  return parsed.isValid() ? parsed.format("YYYY-MM-DD HH:mm") : "-";
}

export const QUESTION_TYPE_LABEL: Record<QuestionType, string> = {
  single_choice: "单选题",
  multiple_choice: "多选题",
  true_false: "判断题",
  fill_blank: "填空题",
  short_answer: "简答题",
};

/** Alias kept for backward-compat with files that used the plural name */
export const QUESTION_TYPE_LABELS = QUESTION_TYPE_LABEL;
