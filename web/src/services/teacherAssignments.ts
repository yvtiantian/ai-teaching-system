import { supabaseRpc } from "@/services/supabaseRpc";
import { apiRequest } from "@/services/api";
import type {
  Assignment,
  AssignmentDetail,
  AssignmentFile,
  AssignmentStats,
  CreateAssignmentPayload,
  GenerateQuestionsPayload,
  GenerateQuestionsResult,
  Question,
  SubmissionSummary,
  UpdateAssignmentPayload,
} from "@/types/assignment";

// ── Row 类型（snake_case，匹配 RPC 返回） ─────────────────

interface AssignmentRow {
  id: string;
  title: string;
  status: "draft" | "published" | "closed";
  deadline: string | null;
  published_at: string | null;
  total_score: number;
  question_count: number | string;
  submitted_count: number | string;
  student_count: number | string;
  created_at: string;
  updated_at: string;
}

/** teacher_create / teacher_update 返回的完整行 */
interface AssignmentFullRow {
  id: string;
  course_id: string;
  teacher_id: string;
  title: string;
  description: string | null;
  ai_prompt: string | null;
  status: "draft" | "published" | "closed";
  deadline: string | null;
  published_at: string | null;
  total_score: number;
  question_config: Record<string, unknown> | null;
  created_at: string;
  updated_at: string;
}

/** teacher_get_assignment_detail 返回的 JSON */
interface AssignmentDetailRow {
  id: string;
  course_id: string;
  course_name: string;
  title: string;
  description: string | null;
  status: "draft" | "published" | "closed";
  deadline: string | null;
  published_at: string | null;
  total_score: number;
  ai_prompt: string | null;
  question_config: Record<string, unknown> | null;
  questions: QuestionRow[];
  files: FileRow[];
  created_at: string;
  updated_at: string;
}

interface QuestionRow {
  id: string;
  question_type: string;
  sort_order: number;
  content: string;
  options: { label: string; text: string }[] | null;
  correct_answer: Record<string, unknown>;
  explanation: string | null;
  score: number;
}

interface FileRow {
  id: string;
  file_name: string;
  storage_path: string;
  file_size: number;
  mime_type: string;
}

interface StatsRow {
  total_students: number;
  submitted_count: number;
  not_submitted_count: number;
  graded_count: number;
  submission_rate: number;
}

interface SubmissionsResultRow {
  total: number;
  page: number;
  page_size: number;
  items: SubmissionItemRow[];
}

interface SubmissionItemRow {
  student_id: string;
  student_name: string | null;
  student_email: string;
  status: string;
  submitted_at: string | null;
  total_score: number | null;
}

// ── 映射（snake → camelCase） ─────────────────────────────

function toAssignment(row: AssignmentRow, courseId?: string): Assignment {
  return {
    id: row.id,
    courseId: courseId ?? "",
    title: row.title,
    description: null,
    status: row.status,
    deadline: row.deadline,
    publishedAt: row.published_at,
    totalScore: Number(row.total_score) || 0,
    questionCount: Number(row.question_count) || 0,
    submissionCount: Number(row.student_count) || 0,
    submittedCount: Number(row.submitted_count) || 0,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function toAssignmentFromFull(row: AssignmentFullRow): Assignment {
  return {
    id: row.id,
    courseId: row.course_id,
    title: row.title,
    description: row.description,
    status: row.status,
    deadline: row.deadline,
    publishedAt: row.published_at,
    totalScore: Number(row.total_score) || 0,
    questionCount: 0,
    submissionCount: 0,
    submittedCount: 0,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function toQuestion(row: QuestionRow): Question {
  return {
    id: row.id,
    questionType: row.question_type as Question["questionType"],
    sortOrder: row.sort_order,
    content: row.content,
    options: row.options,
    correctAnswer: row.correct_answer,
    explanation: row.explanation,
    score: Number(row.score) || 0,
  };
}

function toAssignmentDetail(row: AssignmentDetailRow): AssignmentDetail {
  return {
    id: row.id,
    courseId: row.course_id,
    title: row.title,
    description: row.description,
    status: row.status,
    deadline: row.deadline,
    publishedAt: row.published_at,
    totalScore: Number(row.total_score) || 0,
    questionCount: row.questions?.length ?? 0,
    submissionCount: 0,
    submittedCount: 0,
    aiPrompt: row.ai_prompt,
    questionConfig: row.question_config as AssignmentDetail["questionConfig"],
    questions: (row.questions ?? []).map(toQuestion),
    files: (row.files ?? []).map(toFile),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function toFile(row: FileRow): AssignmentFile {
  return {
    id: row.id,
    fileName: row.file_name,
    storagePath: row.storage_path,
    fileSize: row.file_size,
    mimeType: row.mime_type,
  };
}

function toStats(row: StatsRow): AssignmentStats {
  return {
    totalStudents: row.total_students,
    submittedCount: row.submitted_count,
    notSubmittedCount: row.not_submitted_count,
    gradedCount: row.graded_count,
    submissionRate: row.submission_rate,
  };
}

function toSubmission(row: SubmissionItemRow): SubmissionSummary {
  return {
    studentId: row.student_id,
    studentName: row.student_name,
    studentEmail: row.student_email,
    status: row.status,
    submittedAt: row.submitted_at,
    totalScore: row.total_score,
  };
}

// ── 错误映射 ─────────────────────────────────────────────

function mapError(error: unknown, fallback: string): Error {
  const raw = error instanceof Error ? error.message : String(error);

  if (raw.includes("作业标题不能为空")) return new Error("作业标题不能为空");
  if (raw.includes("作业标题不能超过")) return new Error("作业标题不能超过 200 字");
  if (raw.includes("作业不存在或无权")) return new Error("作业不存在或无权操作");
  if (raw.includes("课程不存在或无权")) return new Error("课程不存在或无权操作");
  if (raw.includes("仅草稿状态")) return new Error("仅草稿状态的作业可操作");
  if (raw.includes("至少包含一道题目")) return new Error("发布前至少需要一道题目");
  if (raw.includes("截止日期")) return new Error("截止日期不能为空或已过期");

  return error instanceof Error ? error : new Error(raw || fallback);
}

// ── 作业 CRUD ────────────────────────────────────────────

export async function teacherListAssignments(courseId: string): Promise<Assignment[]> {
  const rows = await supabaseRpc<AssignmentRow[]>("teacher_list_assignments", {
    p_course_id: courseId,
  });
  return rows.map((r) => toAssignment(r, courseId));
}

export async function teacherCreateAssignment(payload: CreateAssignmentPayload): Promise<Assignment> {
  try {
    const data = await supabaseRpc<AssignmentFullRow[] | AssignmentFullRow>(
      "teacher_create_assignment",
      {
        p_course_id: payload.courseId,
        p_title: payload.title.trim(),
        p_description: payload.description?.trim() || null,
      }
    );
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) throw new Error("创建作业失败：未返回数据");
    return toAssignmentFromFull(row);
  } catch (error) {
    throw mapError(error, "创建作业失败");
  }
}

export async function teacherUpdateAssignment(
  assignmentId: string,
  payload: UpdateAssignmentPayload
): Promise<void> {
  try {
    await supabaseRpc("teacher_update_assignment", {
      p_assignment_id: assignmentId,
      p_title: payload.title?.trim() || null,
      p_description: payload.description !== undefined ? (payload.description?.trim() ?? null) : null,
      p_deadline: payload.deadline ?? null,
    });
  } catch (error) {
    throw mapError(error, "更新作业失败");
  }
}

export async function teacherDeleteAssignment(assignmentId: string): Promise<void> {
  try {
    await supabaseRpc("teacher_delete_assignment", { p_assignment_id: assignmentId });
  } catch (error) {
    throw mapError(error, "删除作业失败");
  }
}

export async function teacherPublishAssignment(assignmentId: string, deadline: string): Promise<void> {
  try {
    await supabaseRpc("teacher_publish_assignment", {
      p_assignment_id: assignmentId,
      p_deadline: deadline,
    });
  } catch (error) {
    throw mapError(error, "发布作业失败");
  }
}

export async function teacherCloseAssignment(assignmentId: string): Promise<void> {
  try {
    await supabaseRpc("teacher_close_assignment", { p_assignment_id: assignmentId });
  } catch (error) {
    throw mapError(error, "关闭作业失败");
  }
}

export async function teacherUpdateDeadline(assignmentId: string, deadline: string): Promise<void> {
  try {
    await supabaseRpc("teacher_update_deadline", {
      p_assignment_id: assignmentId,
      p_deadline: deadline,
    });
  } catch (error) {
    throw mapError(error, "修改截止时间失败");
  }
}

// ── 作业详情 ─────────────────────────────────────────────

export async function teacherGetAssignmentDetail(assignmentId: string): Promise<AssignmentDetail> {
  try {
    const data = await supabaseRpc<AssignmentDetailRow>("teacher_get_assignment_detail", {
      p_assignment_id: assignmentId,
    });
    return toAssignmentDetail(data);
  } catch (error) {
    throw mapError(error, "获取作业详情失败");
  }
}

// ── 题目管理 ─────────────────────────────────────────────

export async function teacherSaveQuestions(
  assignmentId: string,
  questions: Question[]
): Promise<void> {
  try {
    const payload = questions.map((q, idx) => ({
      question_type: q.questionType,
      sort_order: idx + 1,
      content: q.content,
      options: q.options ?? null,
      correct_answer: q.correctAnswer,
      explanation: q.explanation ?? null,
      score: q.score,
    }));
    await supabaseRpc("teacher_save_questions", {
      p_assignment_id: assignmentId,
      p_questions: payload,
    });
  } catch (error) {
    throw mapError(error, "保存题目失败");
  }
}

// ── 统计与提交 ───────────────────────────────────────────

export async function teacherGetAssignmentStats(assignmentId: string): Promise<AssignmentStats> {
  try {
    const data = await supabaseRpc<StatsRow>("teacher_get_assignment_stats", {
      p_assignment_id: assignmentId,
    });
    return toStats(data);
  } catch (error) {
    throw mapError(error, "获取统计数据失败");
  }
}

export async function teacherListSubmissions(
  assignmentId: string,
  query?: { status?: string; page?: number; pageSize?: number }
): Promise<{ items: SubmissionSummary[]; total: number; page: number; pageSize: number }> {
  try {
    const data = await supabaseRpc<SubmissionsResultRow>("teacher_list_submissions", {
      p_assignment_id: assignmentId,
      p_status: query?.status ?? null,
      p_page: query?.page ?? 1,
      p_page_size: query?.pageSize ?? 20,
    });
    return {
      items: (data.items ?? []).map(toSubmission),
      total: data.total,
      page: data.page,
      pageSize: data.page_size,
    };
  } catch (error) {
    throw mapError(error, "获取提交列表失败");
  }
}

// ── AI 题目生成（走 Server API） ─────────────────────────

export async function generateAssignmentQuestions(
  payload: GenerateQuestionsPayload
): Promise<GenerateQuestionsResult> {
  // 转换 camelCase → snake_case 适配 Server API
  const body = {
    course_id: payload.courseId,
    title: payload.title,
    description: payload.description ?? null,
    file_paths: payload.filePaths,
    question_config: Object.fromEntries(
      Object.entries(payload.questionConfig).map(([k, v]) => [
        k,
        { count: v!.count, score_per_question: v!.scorePerQuestion },
      ])
    ),
    ai_prompt: payload.aiPrompt ?? null,
  };

  const data = await apiRequest<{
    questions: QuestionRow[];
    total_score: number;
    generation_meta: { model: string; duration_ms: number };
  }>("/api/assignments/generate", {
    method: "POST",
    body: JSON.stringify(body),
    timeoutMs: 300_000,
  });

  return {
    questions: data.questions.map((q, idx) => ({
      questionType: q.question_type as Question["questionType"],
      sortOrder: q.sort_order ?? idx + 1,
      content: q.content,
      options: q.options,
      correctAnswer: q.correct_answer,
      explanation: q.explanation,
      score: Number(q.score) || 0,
    })),
    totalScore: data.total_score,
    generationMeta: {
      model: data.generation_meta.model,
      durationMs: data.generation_meta.duration_ms,
    },
  };
}
