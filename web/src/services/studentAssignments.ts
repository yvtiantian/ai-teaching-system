import { supabaseRpc } from "@/services/supabaseRpc";
import { apiRequest } from "@/services/api";
import type {
  AnswerResult,
  AssignmentResult,
  SavedAnswer,
  StudentAssignment,
  StudentAssignmentDetail,
  StudentQuestion,
  SubmissionStatus,
  SubmitResult,
} from "@/types/assignment";

// ── Row 类型（snake_case，匹配 RPC 返回） ─────────────────

interface StudentAssignmentRow {
  id: string;
  course_id: string;
  course_name: string;
  title: string;
  description: string | null;
  status: "published" | "closed";
  deadline: string | null;
  total_score: number;
  question_count: number | string;
  submission_status: string;
  submission_score: number | null;
  submitted_at: string | null;
  created_at: string;
}

interface StudentAssignmentDetailRow {
  id: string;
  course_id: string;
  course_name: string;
  title: string;
  description: string | null;
  status: "published" | "closed";
  deadline: string | null;
  total_score: number;
  questions: QuestionRow[];
  saved_answers: SavedAnswerRow[];
  submission_id: string | null;
  submission_status: string;
  submitted_at: string | null;
}

interface QuestionRow {
  id: string;
  question_type: string;
  sort_order: number;
  content: string;
  options: { label: string; text: string }[] | null;
  score: number;
  correct_answer?: Record<string, unknown> | null;
  explanation?: string | null;
}

interface SavedAnswerRow {
  question_id: string;
  answer: unknown;
}

interface SubmissionRow {
  id: string;
  assignment_id: string;
  student_id: string;
  status: string;
  submitted_at: string | null;
  total_score: number | null;
  created_at: string;
  updated_at: string;
}

interface SubmitResultRow {
  submitted_at: string;
  auto_score: number;
  has_subjective: boolean;
  assignment_id: string;
}

interface AnswerResultRow {
  question_id: string;
  question_type: string;
  sort_order: number;
  content: string;
  options: { label: string; text: string }[] | null;
  max_score: number;
  correct_answer: Record<string, unknown> | null;
  explanation: string | null;
  student_answer: unknown;
  score: number;
  is_correct: boolean | null;
  ai_feedback: string | null;
  ai_detail: Record<string, unknown> | null;
  teacher_comment: string | null;
  graded_by: string;
}

interface AssignmentResultRow {
  assignment_id: string;
  course_name: string;
  title: string;
  total_score: number;
  submission_id: string;
  submission_status: string;
  submitted_at: string;
  student_score: number | null;
  answers: AnswerResultRow[];
}

// ── 映射（snake → camelCase） ─────────────────────────────

function toStudentAssignment(row: StudentAssignmentRow): StudentAssignment {
  return {
    id: row.id,
    courseId: row.course_id,
    courseName: row.course_name,
    title: row.title,
    description: row.description,
    status: row.status,
    deadline: row.deadline,
    totalScore: Number(row.total_score) || 0,
    questionCount: Number(row.question_count) || 0,
    submissionStatus: (row.submission_status || "not_started") as SubmissionStatus,
    submissionScore: row.submission_score,
    submittedAt: row.submitted_at,
    createdAt: row.created_at,
  };
}

function toStudentQuestion(row: QuestionRow): StudentQuestion {
  return {
    id: row.id,
    questionType: row.question_type as StudentQuestion["questionType"],
    sortOrder: row.sort_order,
    content: row.content,
    options: row.options,
    score: Number(row.score) || 0,
    correctAnswer: row.correct_answer ?? null,
    explanation: row.explanation ?? null,
  };
}

function toStudentAssignmentDetail(row: StudentAssignmentDetailRow): StudentAssignmentDetail {
  return {
    id: row.id,
    courseId: row.course_id,
    courseName: row.course_name,
    title: row.title,
    description: row.description,
    status: row.status,
    deadline: row.deadline,
    totalScore: Number(row.total_score) || 0,
    questions: (row.questions ?? []).map(toStudentQuestion),
    savedAnswers: (row.saved_answers ?? []).map((a) => ({
      questionId: a.question_id,
      answer: a.answer,
    })),
    submissionId: row.submission_id ?? null,
    submissionStatus: (row.submission_status || "not_started") as SubmissionStatus,
    submittedAt: row.submitted_at,
  };
}

function toAnswerResult(row: AnswerResultRow): AnswerResult {
  return {
    questionId: row.question_id,
    questionType: row.question_type as AnswerResult["questionType"],
    sortOrder: row.sort_order,
    content: row.content,
    options: row.options,
    maxScore: Number(row.max_score) || 0,
    correctAnswer: row.correct_answer ?? null,
    explanation: row.explanation ?? null,
    studentAnswer: row.student_answer,
    score: Number(row.score) || 0,
    isCorrect: row.is_correct,
    aiFeedback: row.ai_feedback,
    aiDetail: row.ai_detail,
    teacherComment: row.teacher_comment,
    gradedBy: row.graded_by || "pending",
  };
}

function toAssignmentResult(row: AssignmentResultRow): AssignmentResult {
  return {
    assignmentId: row.assignment_id,
    courseName: row.course_name,
    title: row.title,
    totalScore: Number(row.total_score) || 0,
    submissionId: row.submission_id,
    submissionStatus: (row.submission_status || "submitted") as SubmissionStatus,
    submittedAt: row.submitted_at,
    studentScore: row.student_score,
    answers: (row.answers ?? []).map(toAnswerResult),
  };
}

// ── 错误映射 ─────────────────────────────────────────────

function mapError(error: unknown, fallback: string): Error {
  const raw = error instanceof Error ? error.message : String(error);

  if (raw.includes("作业不存在")) return new Error("作业不存在或无权查看");
  if (raw.includes("未加入该课程")) return new Error("你未加入该课程");
  if (raw.includes("作业已截止")) return new Error("作业已截止，无法提交");
  if (raw.includes("作业已提交")) return new Error("作业已提交，不可重复提交");
  if (raw.includes("作业未发布")) return new Error("作业未发布或已关闭");
  if (raw.includes("尚未提交")) return new Error("你尚未提交此作业");
  if (raw.includes("无法继续保存")) return new Error("作业已提交，无法继续保存");

  return error instanceof Error ? error : new Error(raw || fallback);
}

// ── 作业列表 ─────────────────────────────────────────────

export async function studentListAssignments(
  courseId?: string
): Promise<StudentAssignment[]> {
  try {
    const rows = await supabaseRpc<StudentAssignmentRow[]>(
      "student_list_assignments",
      { p_course_id: courseId ?? null }
    );
    return rows.map(toStudentAssignment);
  } catch (error) {
    throw mapError(error, "加载作业列表失败");
  }
}

// ── 作业详情（作答视图） ─────────────────────────────────

export async function studentGetAssignment(
  assignmentId: string
): Promise<StudentAssignmentDetail> {
  try {
    const data = await supabaseRpc<StudentAssignmentDetailRow>(
      "student_get_assignment",
      { p_assignment_id: assignmentId }
    );
    return toStudentAssignmentDetail(data);
  } catch (error) {
    throw mapError(error, "获取作业详情失败");
  }
}

// ── 创建/恢复提交记录 ───────────────────────────────────

export async function studentStartSubmission(
  assignmentId: string
): Promise<{ submissionId: string; status: SubmissionStatus }> {
  try {
    const data = await supabaseRpc<SubmissionRow[] | SubmissionRow>(
      "student_start_submission",
      { p_assignment_id: assignmentId }
    );
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) throw new Error("创建提交记录失败");
    return {
      submissionId: row.id,
      status: row.status as SubmissionStatus,
    };
  } catch (error) {
    throw mapError(error, "创建提交记录失败");
  }
}

// ── 保存草稿 ─────────────────────────────────────────────

export async function studentSaveAnswers(
  submissionId: string,
  answers: SavedAnswer[]
): Promise<void> {
  try {
    const payload = answers.map((a) => ({
      question_id: a.questionId,
      answer: a.answer,
    }));
    await supabaseRpc("student_save_answers", {
      p_submission_id: submissionId,
      p_answers: payload,
    });
  } catch (error) {
    throw mapError(error, "保存草稿失败");
  }
}

// ── 提交作业 ─────────────────────────────────────────────

export async function studentSubmit(
  submissionId: string
): Promise<SubmitResult> {
  try {
    const data = await supabaseRpc<SubmitResultRow>(
      "student_submit",
      { p_submission_id: submissionId }
    );
    return {
      submittedAt: data.submitted_at,
      autoScore: Number(data.auto_score) || 0,
      hasSubjective: data.has_subjective,
      assignmentId: data.assignment_id,
    };
  } catch (error) {
    throw mapError(error, "提交作业失败");
  }
}

// ── 触发 AI 批改（提交后含主观题时调用）───────────────

export async function triggerAiGrading(
  submissionId: string
): Promise<void> {
  try {
    await apiRequest("/api/assignments/grade", {
      method: "POST",
      body: JSON.stringify({ submission_id: submissionId }),
    });
  } catch {
    // AI 批改触发失败不影响提交结果，静默忽略
    console.warn("triggerAiGrading failed for", submissionId);
  }
}

// ── 查看成绩结果 ─────────────────────────────────────────

export async function studentGetResult(
  assignmentId: string
): Promise<AssignmentResult> {
  try {
    const data = await supabaseRpc<AssignmentResultRow>(
      "student_get_result",
      { p_assignment_id: assignmentId }
    );
    return toAssignmentResult(data);
  } catch (error) {
    throw mapError(error, "获取成绩详情失败");
  }
}
