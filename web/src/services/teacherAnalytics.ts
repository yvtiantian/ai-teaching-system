import { supabaseRpc } from "@/services/supabaseRpc";
import { getAccessToken } from "@/lib/supabase";
import type {
  CourseAnalytics,
  CourseAssignmentSummary,
  ScoreDistribution,
  ScoreBucket,
  ScoreDistributionStats,
  QuestionAnalysis,
  QuestionAnalysisItem,
  ErrorQuestionListResult,
  ErrorQuestionItem,
  CommonWrongAnswer,
  AnswerDistributionItem,
  ClassTrend,
  ClassTrendItem,
  StudentLearningProfile,
  StudentAssignmentTrack,
  StudentProfileSummary,
  CourseStudentsOverview,
  CourseStudentOverviewItem,
  QuestionType,
  SubmissionStatus,
} from "@/types/assignment";

// ── Row 类型（snake_case，匹配 RPC 返回） ─────────────────

interface CourseAnalyticsRow {
  course_id: string;
  total_students: number;
  assignment_count: number;
  assignments: Array<{
    id: string;
    title: string;
    status: string;
    total_score: number;
    deadline: string | null;
    created_at: string;
    submitted_count: number;
    avg_score: number | null;
    max_score: number | null;
    min_score: number | null;
  }>;
}

interface ScoreDistributionRow {
  assignment_id: string;
  total_score: number;
  distribution: Array<{ bucket: string; count: number }>;
  stats: {
    graded_count: number;
    avg_score: number | null;
    max_score: number | null;
    min_score: number | null;
    std_dev: number | null;
  };
}

interface QuestionAnalysisRow {
  assignment_id: string;
  questions: Array<{
    question_id: string;
    question_type: string;
    sort_order: number;
    content: string;
    max_score: number;
    correct_answer: Record<string, unknown>;
    options: Array<{ label: string; text: string }> | null;
    explanation: string | null;
    total_answers: number;
    correct_count: number;
    wrong_count: number;
    correct_rate: number;
    avg_score_rate: number;
    answer_distribution: Array<{ answer: unknown; count: number }>;
  }>;
}

interface ErrorQuestionListRow {
  total: number;
  page: number;
  page_size: number;
  items: Array<{
    question_id: string;
    question_type: string;
    sort_order: number;
    content: string;
    max_score: number;
    correct_answer: Record<string, unknown>;
    options: Array<{ label: string; text: string }> | null;
    explanation: string | null;
    assignment_id: string;
    assignment_title: string;
    total_answers: number;
    wrong_count: number;
    error_rate: number;
    common_wrong_answers: Array<{ answer: unknown; count: number }>;
  }>;
}

interface ClassTrendRow {
  course_id: string;
  trends: Array<{
    id: string;
    title: string;
    total_score: number;
    created_at: string;
    submitted_count: number;
    total_students: number;
    avg_score: number | null;
    submission_rate: number;
  }>;
}

interface StudentProfileRow {
  student_id: string;
  student_name: string;
  student_email: string;
  assignments: Array<{
    assignment_id: string;
    title: string;
    max_score: number;
    created_at: string;
    submission_id: string | null;
    status: string | null;
    student_score: number | null;
    submitted_at: string | null;
    score_rate: number | null;
    wrong_count: number;
    total_questions: number;
  }>;
  summary: {
    total_assignments: number;
    submitted_count: number;
    avg_score_rate: number | null;
    total_wrong_count: number;
  };
}

interface CourseStudentsOverviewRow {
  students: Array<{
    student_id: string;
    student_name: string;
    student_email: string;
    avg_score_rate: number | null;
    graded_count: number;
  }>;
}

// ── 映射 ─────────────────────────────────────────────────

function toCourseAnalytics(row: CourseAnalyticsRow): CourseAnalytics {
  return {
    courseId: row.course_id,
    totalStudents: row.total_students,
    assignmentCount: row.assignment_count,
    assignments: (row.assignments ?? []).map(
      (a): CourseAssignmentSummary => ({
        id: a.id,
        title: a.title,
        status: a.status as CourseAssignmentSummary["status"],
        totalScore: Number(a.total_score) || 0,
        deadline: a.deadline,
        createdAt: a.created_at,
        submittedCount: Number(a.submitted_count) || 0,
        avgScore: a.avg_score != null ? Number(a.avg_score) : null,
        maxScore: a.max_score != null ? Number(a.max_score) : null,
        minScore: a.min_score != null ? Number(a.min_score) : null,
      })
    ),
  };
}

function toScoreDistribution(row: ScoreDistributionRow): ScoreDistribution {
  return {
    assignmentId: row.assignment_id,
    totalScore: Number(row.total_score) || 0,
    distribution: (row.distribution ?? []).map(
      (d): ScoreBucket => ({ bucket: d.bucket, count: Number(d.count) || 0 })
    ),
    stats: {
      gradedCount: Number(row.stats?.graded_count) || 0,
      avgScore: row.stats?.avg_score != null ? Number(row.stats.avg_score) : null,
      maxScore: row.stats?.max_score != null ? Number(row.stats.max_score) : null,
      minScore: row.stats?.min_score != null ? Number(row.stats.min_score) : null,
      stdDev: row.stats?.std_dev != null ? Number(row.stats.std_dev) : null,
    } as ScoreDistributionStats,
  };
}

function toQuestionAnalysis(row: QuestionAnalysisRow): QuestionAnalysis {
  return {
    assignmentId: row.assignment_id,
    questions: (row.questions ?? []).map(
      (q): QuestionAnalysisItem => ({
        questionId: q.question_id,
        questionType: q.question_type as QuestionType,
        sortOrder: q.sort_order,
        content: q.content,
        maxScore: Number(q.max_score) || 0,
        correctAnswer: q.correct_answer,
        totalAnswers: Number(q.total_answers) || 0,
        correctCount: Number(q.correct_count) || 0,
        wrongCount: Number(q.wrong_count) || 0,
        correctRate: Number(q.correct_rate) || 0,
        avgScoreRate: Number(q.avg_score_rate) || 0,
        options: q.options ?? null,
        explanation: q.explanation ?? null,
        answerDistribution: (q.answer_distribution ?? []).map(
          (a): AnswerDistributionItem => ({ answer: a.answer, count: Number(a.count) || 0 })
        ),
      })
    ),
  };
}

function toErrorQuestionList(row: ErrorQuestionListRow): ErrorQuestionListResult {
  return {
    total: row.total,
    page: row.page,
    pageSize: row.page_size,
    items: (row.items ?? []).map(
      (q): ErrorQuestionItem => ({
        questionId: q.question_id,
        questionType: q.question_type as QuestionType,
        sortOrder: q.sort_order,
        content: q.content,
        maxScore: Number(q.max_score) || 0,
        correctAnswer: q.correct_answer,
        options: q.options ?? null,
        explanation: q.explanation,
        assignmentId: q.assignment_id,
        assignmentTitle: q.assignment_title,
        totalAnswers: Number(q.total_answers) || 0,
        wrongCount: Number(q.wrong_count) || 0,
        errorRate: Number(q.error_rate) || 0,
        commonWrongAnswers: (q.common_wrong_answers ?? []).map(
          (a): CommonWrongAnswer => ({ answer: a.answer, count: Number(a.count) || 0 })
        ),
      })
    ),
  };
}

function toClassTrend(row: ClassTrendRow): ClassTrend {
  return {
    courseId: row.course_id,
    trends: (row.trends ?? []).map(
      (t): ClassTrendItem => ({
        id: t.id,
        title: t.title,
        totalScore: Number(t.total_score) || 0,
        createdAt: t.created_at,
        submittedCount: Number(t.submitted_count) || 0,
        totalStudents: Number(t.total_students) || 0,
        avgScore: t.avg_score != null ? Number(t.avg_score) : null,
        submissionRate: Number(t.submission_rate) || 0,
      })
    ),
  };
}

function toStudentProfile(row: StudentProfileRow): StudentLearningProfile {
  return {
    studentId: row.student_id,
    studentName: row.student_name,
    studentEmail: row.student_email,
    assignments: (row.assignments ?? []).map(
      (a): StudentAssignmentTrack => ({
        assignmentId: a.assignment_id,
        title: a.title,
        maxScore: Number(a.max_score) || 0,
        createdAt: a.created_at,
        submissionId: a.submission_id,
        status: a.status as SubmissionStatus | null,
        studentScore: a.student_score != null ? Number(a.student_score) : null,
        submittedAt: a.submitted_at,
        scoreRate: a.score_rate != null ? Number(a.score_rate) : null,
        wrongCount: Number(a.wrong_count) || 0,
        totalQuestions: Number(a.total_questions) || 0,
      })
    ),
    summary: {
      totalAssignments: Number(row.summary?.total_assignments) || 0,
      submittedCount: Number(row.summary?.submitted_count) || 0,
      avgScoreRate: row.summary?.avg_score_rate != null ? Number(row.summary.avg_score_rate) : null,
      totalWrongCount: Number(row.summary?.total_wrong_count) || 0,
    } as StudentProfileSummary,
  };
}

function toCourseStudentsOverview(row: CourseStudentsOverviewRow): CourseStudentsOverview {
  return {
    students: (row.students ?? []).map(
      (s): CourseStudentOverviewItem => ({
        studentId: s.student_id,
        studentName: s.student_name,
        studentEmail: s.student_email,
        avgScoreRate: s.avg_score_rate != null ? Number(s.avg_score_rate) : null,
        gradedCount: Number(s.graded_count) || 0,
      })
    ),
  };
}

// ── API 函数 ─────────────────────────────────────────────

export async function teacherGetCourseAnalytics(courseId: string): Promise<CourseAnalytics> {
  const data = await supabaseRpc<CourseAnalyticsRow>("teacher_get_course_analytics", {
    p_course_id: courseId,
  });
  return toCourseAnalytics(data);
}

export async function teacherGetScoreDistribution(assignmentId: string): Promise<ScoreDistribution> {
  const data = await supabaseRpc<ScoreDistributionRow>("teacher_get_score_distribution", {
    p_assignment_id: assignmentId,
  });
  return toScoreDistribution(data);
}

export async function teacherGetQuestionAnalysis(assignmentId: string): Promise<QuestionAnalysis> {
  const data = await supabaseRpc<QuestionAnalysisRow>("teacher_get_question_analysis", {
    p_assignment_id: assignmentId,
  });
  return toQuestionAnalysis(data);
}

export async function teacherGetErrorQuestions(
  courseId: string,
  query?: { assignmentId?: string; page?: number; pageSize?: number }
): Promise<ErrorQuestionListResult> {
  const data = await supabaseRpc<ErrorQuestionListRow>("teacher_get_error_questions", {
    p_course_id: courseId,
    p_assignment_id: query?.assignmentId ?? null,
    p_page: query?.page ?? 1,
    p_page_size: query?.pageSize ?? 20,
  });
  return toErrorQuestionList(data);
}

export async function teacherGetClassTrend(
  courseId: string,
  limit: number = 10
): Promise<ClassTrend> {
  const data = await supabaseRpc<ClassTrendRow>("teacher_get_class_trend", {
    p_course_id: courseId,
    p_limit: limit,
  });
  return toClassTrend(data);
}

export async function teacherGetStudentProfile(
  courseId: string,
  studentId: string
): Promise<StudentLearningProfile> {
  const data = await supabaseRpc<StudentProfileRow>("teacher_get_student_profile", {
    p_course_id: courseId,
    p_student_id: studentId,
  });
  return toStudentProfile(data);
}

export async function teacherGetCourseStudentsOverview(
  courseId: string
): Promise<CourseStudentsOverview> {
  const data = await supabaseRpc<CourseStudentsOverviewRow>("teacher_get_course_students_overview", {
    p_course_id: courseId,
  });
  return toCourseStudentsOverview(data);
}

// ── AI 分析（SSE 流式） ──────────────────────────────────

async function streamAnalysis(
  path: string,
  body: Record<string, string>,
  onToken: (text: string) => void,
  signal?: AbortSignal,
): Promise<void> {
  const baseUrl = import.meta.env.VITE_API_URL ?? "http://localhost:8100";
  const token = await getAccessToken();

  const response = await fetch(`${baseUrl}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
    signal,
  });

  if (!response.ok) {
    const err = await response.json().catch(() => ({}));
    throw new Error((err as { detail?: string }).detail || "请求失败");
  }

  const reader = response.body?.getReader();
  if (!reader) throw new Error("无法读取响应流");

  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";

    for (const line of lines) {
      if (!line.startsWith("data: ")) continue;
      const data = line.slice(6).trim();
      if (data === "[DONE]") continue;
      try {
        const parsed = JSON.parse(data) as { content?: string; error?: string };
        if (parsed.error) throw new Error(parsed.error);
        if (parsed.content) onToken(parsed.content);
      } catch (e) {
        if (e instanceof SyntaxError) continue;
        throw e;
      }
    }
  }
}

export function streamErrorAnalysis(
  assignmentId: string,
  questionId: string,
  onToken: (text: string) => void,
  signal?: AbortSignal,
): Promise<void> {
  return streamAnalysis(
    "/api/analytics/error-analysis",
    { assignment_id: assignmentId, question_id: questionId },
    onToken,
    signal,
  );
}
