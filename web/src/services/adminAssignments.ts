import { supabaseRpc } from "@/services/supabaseRpc";
import type {
  AdminAssignment,
  AdminAssignmentDetail,
  AdminAssignmentListResult,
  AdminAssignmentStats,
  AdminSubmission,
  AdminSubmissionAnswer,
  AdminSubmissionDetail,
  AdminSubmissionListResult,
  Question,
} from "@/types/assignment";

// ── Row interfaces (snake_case from DB) ──────────────────

interface AssignmentListRow {
  total: number;
  page: number;
  page_size: number;
  items: Array<{
    id: string;
    title: string;
    course_id: string;
    course_name: string;
    teacher_id: string;
    teacher_name: string;
    status: string;
    deadline: string | null;
    total_score: number;
    question_count: number;
    created_at: string;
    updated_at: string;
  }>;
}

interface AssignmentDetailRow {
  assignment: {
    id: string;
    title: string;
    description: string | null;
    status: string;
    deadline: string | null;
    published_at: string | null;
    total_score: number;
    question_config: Record<string, unknown> | null;
    course_id: string;
    course_name: string;
    teacher_id: string;
    teacher_name: string;
    created_at: string;
    updated_at: string;
  };
  questions: Array<{
    id: string;
    question_type: string;
    sort_order: number;
    content: string;
    options: unknown;
    correct_answer: Record<string, unknown>;
    explanation: string | null;
    score: number;
  }>;
  stats: {
    student_count: number;
    submitted_count: number;
    auto_graded_count: number;
    ai_graded_count: number;
    graded_count: number;
    avg_score: number | null;
    max_score: number | null;
    min_score: number | null;
  };
}

interface SubmissionListRow {
  total: number;
  page: number;
  page_size: number;
  items: Array<{
    id: string;
    student_id: string;
    student_name: string;
    status: string;
    submitted_at: string | null;
    total_score: number | null;
    created_at: string;
    updated_at: string;
  }>;
}

interface SubmissionDetailRow {
  submission: {
    id: string;
    assignment_id: string;
    student_id: string;
    student_name: string;
    status: string;
    submitted_at: string | null;
    total_score: number | null;
  };
  answers: Array<{
    id: string;
    question_id: string;
    question_type: string;
    sort_order: number;
    content: string;
    options: unknown;
    correct_answer: Record<string, unknown>;
    explanation: string | null;
    max_score: number;
    answer: unknown;
    is_correct: boolean | null;
    score: number;
    ai_score: number | null;
    ai_feedback: string | null;
    ai_detail: Record<string, unknown> | null;
    teacher_comment: string | null;
    graded_by: string;
  }>;
  navigation: {
    prev_submission_id: string | null;
    next_submission_id: string | null;
  };
}

// ── Transformers ─────────────────────────────────────────

function toAdminAssignment(row: AssignmentListRow["items"][number]): AdminAssignment {
  return {
    id: row.id,
    title: row.title,
    courseId: row.course_id,
    courseName: row.course_name,
    teacherId: row.teacher_id,
    teacherName: row.teacher_name,
    status: row.status as AdminAssignment["status"],
    deadline: row.deadline,
    totalScore: row.total_score,
    questionCount: row.question_count,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function toAdminAssignmentDetail(row: AssignmentDetailRow): AdminAssignmentDetail {
  const a = row.assignment;
  return {
    assignment: {
      id: a.id,
      title: a.title,
      description: a.description,
      status: a.status as AdminAssignmentDetail["assignment"]["status"],
      deadline: a.deadline,
      publishedAt: a.published_at,
      totalScore: a.total_score,
      questionConfig: a.question_config as AdminAssignmentDetail["assignment"]["questionConfig"],
      courseId: a.course_id,
      courseName: a.course_name,
      teacherId: a.teacher_id,
      teacherName: a.teacher_name,
      createdAt: a.created_at,
      updatedAt: a.updated_at,
    },
    questions: row.questions.map(
      (q): Question => ({
        id: q.id,
        questionType: q.question_type as Question["questionType"],
        sortOrder: q.sort_order,
        content: q.content,
        options: q.options as Question["options"],
        correctAnswer: q.correct_answer,
        explanation: q.explanation,
        score: q.score,
      }),
    ),
    stats: toStats(row.stats),
  };
}

function toStats(s: AssignmentDetailRow["stats"]): AdminAssignmentStats {
  return {
    studentCount: Number(s.student_count) || 0,
    submittedCount: Number(s.submitted_count) || 0,
    reviewableCount: Number(s.auto_graded_count) || 0,
    reviewPendingCount: Number(s.ai_graded_count) || 0,
    gradedCount: Number(s.graded_count) || 0,
    avgScore: s.avg_score != null ? Number(s.avg_score) : null,
    maxScore: s.max_score != null ? Number(s.max_score) : null,
    minScore: s.min_score != null ? Number(s.min_score) : null,
  };
}

function toAdminSubmission(row: SubmissionListRow["items"][number]): AdminSubmission {
  return {
    id: row.id,
    studentId: row.student_id,
    studentName: row.student_name,
    status: row.status as AdminSubmission["status"],
    submittedAt: row.submitted_at,
    totalScore: row.total_score,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function toAdminSubmissionDetail(row: SubmissionDetailRow): AdminSubmissionDetail {
  const sub = row.submission;
  return {
    submission: {
      id: sub.id,
      assignmentId: sub.assignment_id,
      studentId: sub.student_id,
      studentName: sub.student_name,
      status: sub.status as AdminSubmissionDetail["submission"]["status"],
      submittedAt: sub.submitted_at,
      totalScore: sub.total_score,
    },
    answers: row.answers.map(
      (a): AdminSubmissionAnswer => ({
        id: a.id,
        questionId: a.question_id,
        questionType: a.question_type as AdminSubmissionAnswer["questionType"],
        sortOrder: a.sort_order,
        content: a.content,
        options: a.options as AdminSubmissionAnswer["options"],
        correctAnswer: a.correct_answer,
        explanation: a.explanation,
        maxScore: a.max_score,
        answer: a.answer,
        isCorrect: a.is_correct,
        score: a.score,
        aiScore: a.ai_score,
        aiFeedback: a.ai_feedback,
        aiDetail: a.ai_detail,
        teacherComment: a.teacher_comment,
        gradedBy: a.graded_by,
      }),
    ),
    navigation: {
      prevSubmissionId: row.navigation.prev_submission_id,
      nextSubmissionId: row.navigation.next_submission_id,
    },
  };
}

// ── Error mapper ─────────────────────────────────────────

function mapError(error: unknown, fallback: string): Error {
  const raw = error instanceof Error ? error.message : String(error);

  if (raw.includes("仅管理员可执行此操作")) return new Error("仅管理员可执行此操作");
  if (raw.includes("作业不存在")) return new Error("作业不存在");
  if (raw.includes("提交记录不存在")) return new Error("提交记录不存在");
  if (raw.includes("只有已发布的作业可以修改截止日期")) return new Error("只有已发布的作业可以修改截止日期");
  if (raw.includes("只有已发布的作业可以关闭")) return new Error("只有已发布的作业可以关闭");
  if (raw.includes("只有已关闭的作业可以重新开放")) return new Error("只有已关闭的作业可以重新开放");
  if (raw.includes("截止日期必须是未来时间")) return new Error("截止日期必须是未来时间");
  if (raw.includes("重新开放作业必须设置新的截止日期")) return new Error("重新开放作业必须设置新的截止日期");

  return error instanceof Error ? error : new Error(raw || fallback);
}

// ── Exported service functions ───────────────────────────

export async function adminListAssignments(query?: {
  keyword?: string;
  courseId?: string;
  status?: string;
  page?: number;
  pageSize?: number;
}): Promise<AdminAssignmentListResult> {
  try {
    const res = await supabaseRpc<AssignmentListRow>("admin_list_assignments", {
      p_keyword: query?.keyword?.trim() || null,
      p_course_id: query?.courseId || null,
      p_status: query?.status || null,
      p_page: query?.page ?? 1,
      p_page_size: query?.pageSize ?? 20,
    });
    return {
      items: (res.items || []).map(toAdminAssignment),
      total: res.total,
      page: res.page,
      pageSize: res.page_size,
    };
  } catch (error) {
    throw mapError(error, "获取作业列表失败");
  }
}

export async function adminGetAssignmentDetail(
  assignmentId: string,
): Promise<AdminAssignmentDetail> {
  try {
    const res = await supabaseRpc<AssignmentDetailRow>("admin_get_assignment_detail", {
      p_assignment_id: assignmentId,
    });
    return toAdminAssignmentDetail(res);
  } catch (error) {
    throw mapError(error, "获取作业详情失败");
  }
}

export async function adminUpdateAssignment(
  assignmentId: string,
  payload: { deadline?: string; status?: string },
): Promise<void> {
  try {
    await supabaseRpc("admin_update_assignment", {
      p_assignment_id: assignmentId,
      p_deadline: payload.deadline || null,
      p_status: payload.status || null,
    });
  } catch (error) {
    throw mapError(error, "更新作业失败");
  }
}

export async function adminDeleteAssignment(assignmentId: string): Promise<void> {
  try {
    await supabaseRpc("admin_delete_assignment", {
      p_assignment_id: assignmentId,
    });
  } catch (error) {
    throw mapError(error, "删除作业失败");
  }
}

export async function adminListSubmissions(
  assignmentId: string,
  query?: { status?: string; page?: number; pageSize?: number },
): Promise<AdminSubmissionListResult> {
  try {
    const res = await supabaseRpc<SubmissionListRow>("admin_list_submissions", {
      p_assignment_id: assignmentId,
      p_status: query?.status || null,
      p_page: query?.page ?? 1,
      p_page_size: query?.pageSize ?? 20,
    });
    return {
      items: (res.items || []).map(toAdminSubmission),
      total: res.total,
      page: res.page,
      pageSize: res.page_size,
    };
  } catch (error) {
    throw mapError(error, "获取提交列表失败");
  }
}

export async function adminGetSubmissionDetail(
  submissionId: string,
): Promise<AdminSubmissionDetail> {
  try {
    const res = await supabaseRpc<SubmissionDetailRow>("admin_get_submission_detail", {
      p_submission_id: submissionId,
    });
    return toAdminSubmissionDetail(res);
  } catch (error) {
    throw mapError(error, "获取提交详情失败");
  }
}
