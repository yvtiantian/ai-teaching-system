// ── 枚举 / 字面量 ─────────────────────────────────────────

export type AssignmentStatus = "draft" | "published" | "closed";

export type QuestionType =
  | "single_choice"
  | "multiple_choice"
  | "fill_blank"
  | "true_false"
  | "short_answer";

// ── 题目配置 ──────────────────────────────────────────────

/** 单种题型的生成配置 */
export interface QuestionTypeConfig {
  count: number;
  scorePerQuestion: number;
}

/** 完整的题型配置（允许部分题型为空） */
export type QuestionConfig = Partial<Record<QuestionType, QuestionTypeConfig>>;

// ── 题目选项 ──────────────────────────────────────────────

export interface QuestionOption {
  label: string; // "A", "B", "C", "D"
  text: string;
}

// ── 题目 ──────────────────────────────────────────────────

export interface Question {
  id?: string;
  questionType: QuestionType;
  sortOrder: number;
  content: string;
  options?: QuestionOption[] | null;
  correctAnswer: Record<string, unknown>;
  explanation?: string | null;
  score: number;
}

// ── 作业（列表项） ───────────────────────────────────────

export interface Assignment {
  id: string;
  courseId: string;
  title: string;
  description: string | null;
  status: AssignmentStatus;
  deadline: string | null;
  publishedAt: string | null;
  totalScore: number;
  questionCount: number;
  submissionCount: number;
  submittedCount: number;
  createdAt: string;
  updatedAt: string;
}

// ── 作业详情 ─────────────────────────────────────────────

export interface AssignmentFile {
  id: string;
  fileName: string;
  storagePath: string;
  fileSize: number;
  mimeType: string;
}

export interface AssignmentDetail extends Assignment {
  questions: Question[];
  aiPrompt: string | null;
  questionConfig: QuestionConfig | null;
  files: AssignmentFile[];
}

// ── 统计 ─────────────────────────────────────────────────

export interface AssignmentStats {
  totalStudents: number;
  submittedCount: number;
  notSubmittedCount: number;
  gradedCount: number;
  submissionRate: number;
}

export interface SubmissionSummary {
  studentId: string;
  studentName: string | null;
  studentEmail: string;
  status: string;
  submittedAt: string | null;
  totalScore: number | null;
}

// ── 变更载荷 ─────────────────────────────────────────────

export interface CreateAssignmentPayload {
  courseId: string;
  title: string;
  description?: string | null;
}

export interface UpdateAssignmentPayload {
  title?: string;
  description?: string | null;
  deadline?: string | null;
}

// ── AI 生成 ──────────────────────────────────────────────

export interface GenerateQuestionsPayload {
  courseId: string;
  title: string;
  description?: string | null;
  filePaths: string[];
  questionConfig: QuestionConfig;
  aiPrompt?: string | null;
}

export interface GenerateQuestionsResult {
  questions: Question[];
  totalScore: number;
  generationMeta: {
    model: string;
    durationMs: number;
  };
}
