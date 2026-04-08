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
  reviewableCount: number;
  reviewPendingCount: number;
  gradedCount: number;
  submissionRate: number;
}

export interface SubmissionSummary {
  studentId: string;
  studentName: string | null;
  studentEmail: string;
  submissionId: string | null;
  status: string;
  submittedAt: string | null;
  totalScore: number | null;
  assignmentTotalScore: number;
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

// ── 学生端类型 ───────────────────────────────────────────

export type SubmissionStatus =
  | "not_started"
  | "in_progress"
  | "submitted"
  | "ai_grading"
  | "auto_graded"
  | "ai_graded"
  | "graded";

/** 学生作业列表项 */
export interface StudentAssignment {
  id: string;
  courseId: string;
  courseName: string;
  title: string;
  description: string | null;
  status: AssignmentStatus;
  deadline: string | null;
  totalScore: number;
  questionCount: number;
  submissionStatus: SubmissionStatus;
  teacherReviewed: boolean;
  submissionScore: number | null;
  submittedAt: string | null;
  createdAt: string;
}

/** student_get_assignment 返回的作答视图 */
export interface StudentAssignmentDetail {
  id: string;
  courseId: string;
  courseName: string;
  title: string;
  description: string | null;
  status: AssignmentStatus;
  deadline: string | null;
  totalScore: number;
  questions: StudentQuestion[];
  savedAnswers: SavedAnswer[];
  submissionId: string | null;
  submissionStatus: SubmissionStatus;
  submittedAt: string | null;
}

/** 作答视图中的题目（可能不含 correctAnswer） */
export interface StudentQuestion {
  id: string;
  questionType: QuestionType;
  sortOrder: number;
  content: string;
  options?: QuestionOption[] | null;
  score: number;
  correctAnswer?: Record<string, unknown> | null;
  explanation?: string | null;
}

export interface SavedAnswer {
  questionId: string;
  answer: unknown;
}

/** student_submit 返回：hasSubjective 表示仍有需要 AI 处理的简答题 */
export interface SubmitResult {
  submittedAt: string;
  autoScore: number;
  hasSubjective: boolean;
  assignmentId: string;
}

/** student_get_result 中每题的答案详情 */
export interface AnswerResult {
  questionId: string;
  questionType: QuestionType;
  sortOrder: number;
  content: string;
  options?: QuestionOption[] | null;
  maxScore: number;
  correctAnswer?: Record<string, unknown> | null;
  explanation?: string | null;
  studentAnswer: unknown;
  score: number;
  isCorrect: boolean | null;
  aiFeedback: string | null;
  aiDetail: Record<string, unknown> | null;
  teacherComment: string | null;
  gradedBy: string;
}

/** student_get_result 返回 */
export interface AssignmentResult {
  assignmentId: string;
  courseName: string;
  title: string;
  totalScore: number;
  submissionId: string;
  submissionStatus: SubmissionStatus;
  teacherReviewed: boolean;
  submittedAt: string;
  studentScore: number | null;
  answers: AnswerResult[];
}

// ── 教师复核/阅卷类型 ─────────────────────────────────────

export interface SubmissionDetailAnswer {
  answerId: string | null;
  questionId: string;
  questionType: QuestionType;
  sortOrder: number;
  content: string;
  options: QuestionOption[] | null;
  correctAnswer: Record<string, unknown>;
  explanation: string | null;
  maxScore: number;
  studentAnswer: Record<string, unknown>;
  score: number;
  isCorrect: boolean | null;
  aiScore: number | null;
  aiFeedback: string | null;
  aiDetail: Record<string, unknown> | null;
  teacherComment: string | null;
  gradedBy: string;
}

export interface SubmissionDetail {
  submissionId: string;
  assignmentId: string;
  assignmentTitle: string;
  assignmentTotalScore: number;
  studentId: string;
  studentName: string | null;
  studentEmail: string;
  status: SubmissionStatus;
  submittedAt: string | null;
  totalScore: number | null;
  answers: SubmissionDetailAnswer[];
}

// ── 管理员端类型 ──────────────────────────────────────────

/** admin_list_assignments 列表项 */
export interface AdminAssignment {
  id: string;
  title: string;
  courseId: string;
  courseName: string;
  teacherId: string;
  teacherName: string;
  status: AssignmentStatus;
  deadline: string | null;
  totalScore: number;
  questionCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface AdminAssignmentListResult {
  items: AdminAssignment[];
  total: number;
  page: number;
  pageSize: number;
}

/** admin_get_assignment_detail 返回 */
export interface AdminAssignmentStats {
  studentCount: number;
  submittedCount: number;
  reviewableCount: number;
  reviewPendingCount: number;
  gradedCount: number;
  avgScore: number | null;
  maxScore: number | null;
  minScore: number | null;
}

export interface AdminAssignmentDetail {
  assignment: {
    id: string;
    title: string;
    description: string | null;
    status: AssignmentStatus;
    deadline: string | null;
    publishedAt: string | null;
    totalScore: number;
    questionConfig: QuestionConfig | null;
    courseId: string;
    courseName: string;
    teacherId: string;
    teacherName: string;
    createdAt: string;
    updatedAt: string;
  };
  questions: Question[];
  stats: AdminAssignmentStats;
}

/** admin_list_submissions 列表项 */
export interface AdminSubmission {
  id: string;
  studentId: string;
  studentName: string;
  status: SubmissionStatus;
  submittedAt: string | null;
  totalScore: number | null;
  createdAt: string;
  updatedAt: string;
}

export interface AdminSubmissionListResult {
  items: AdminSubmission[];
  total: number;
  page: number;
  pageSize: number;
}

/** admin_get_submission_detail 返回 */
export interface AdminSubmissionAnswer {
  id: string;
  questionId: string;
  questionType: QuestionType;
  sortOrder: number;
  content: string;
  options: QuestionOption[] | null;
  correctAnswer: Record<string, unknown>;
  explanation: string | null;
  maxScore: number;
  answer: unknown;
  isCorrect: boolean | null;
  score: number;
  aiScore: number | null;
  aiFeedback: string | null;
  aiDetail: Record<string, unknown> | null;
  teacherComment: string | null;
  gradedBy: string;
}

export interface AdminSubmissionDetail {
  submission: {
    id: string;
    assignmentId: string;
    studentId: string;
    studentName: string;
    status: SubmissionStatus;
    submittedAt: string | null;
    totalScore: number | null;
  };
  answers: AdminSubmissionAnswer[];
  navigation: {
    prevSubmissionId: string | null;
    nextSubmissionId: string | null;
  };
}

// ── 数据分析类型 ──────────────────────────────────────────

/** 课程分析 — 单作业汇总 */
export interface CourseAssignmentSummary {
  id: string;
  title: string;
  status: AssignmentStatus;
  totalScore: number;
  deadline: string | null;
  createdAt: string;
  submittedCount: number;
  avgScore: number | null;
  maxScore: number | null;
  minScore: number | null;
}

/** teacher_get_course_analytics 返回 */
export interface CourseAnalytics {
  courseId: string;
  totalStudents: number;
  assignmentCount: number;
  assignments: CourseAssignmentSummary[];
}

/** 分数段 */
export interface ScoreBucket {
  bucket: string;
  count: number;
}

export interface ScoreDistributionStats {
  gradedCount: number;
  avgScore: number | null;
  maxScore: number | null;
  minScore: number | null;
  stdDev: number | null;
}

/** teacher_get_score_distribution 返回 */
export interface ScoreDistribution {
  assignmentId: string;
  totalScore: number;
  distribution: ScoreBucket[];
  stats: ScoreDistributionStats;
}

/** 题目错误率分析 */
export interface QuestionAnalysisItem {
  questionId: string;
  questionType: QuestionType;
  sortOrder: number;
  content: string;
  maxScore: number;
  correctAnswer: Record<string, unknown>;
  options: QuestionOption[] | null;
  explanation: string | null;
  totalAnswers: number;
  correctCount: number;
  wrongCount: number;
  correctRate: number;
  avgScoreRate: number;
  answerDistribution: AnswerDistributionItem[];
}

/** teacher_get_question_analysis 返回 */
export interface QuestionAnalysis {
  assignmentId: string;
  questions: QuestionAnalysisItem[];
}

/** 错误答案条目 */
export interface CommonWrongAnswer {
  answer: unknown;
  count: number;
}

export interface AnswerDistributionItem {
  answer: unknown;
  count: number;
}

/** 错题列表项 */
export interface ErrorQuestionItem {
  questionId: string;
  questionType: QuestionType;
  sortOrder: number;
  content: string;
  maxScore: number;
  correctAnswer: Record<string, unknown>;
  options: QuestionOption[] | null;
  explanation: string | null;
  assignmentId: string;
  assignmentTitle: string;
  totalAnswers: number;
  wrongCount: number;
  errorRate: number;
  commonWrongAnswers: CommonWrongAnswer[];
}

export interface ErrorQuestionListResult {
  items: ErrorQuestionItem[];
  total: number;
  page: number;
  pageSize: number;
}

/** 趋势数据项 */
export interface ClassTrendItem {
  id: string;
  title: string;
  totalScore: number;
  createdAt: string;
  submittedCount: number;
  totalStudents: number;
  avgScore: number | null;
  submissionRate: number;
}

/** teacher_get_class_trend 返回 */
export interface ClassTrend {
  courseId: string;
  trends: ClassTrendItem[];
}

/** 学生作业轨迹项 */
export interface StudentAssignmentTrack {
  assignmentId: string;
  title: string;
  maxScore: number;
  createdAt: string;
  submissionId: string | null;
  status: SubmissionStatus | null;
  studentScore: number | null;
  submittedAt: string | null;
  scoreRate: number | null;
  wrongCount: number;
  totalQuestions: number;
}

export interface StudentProfileSummary {
  totalAssignments: number;
  submittedCount: number;
  avgScoreRate: number | null;
  totalWrongCount: number;
}

/** teacher_get_student_profile 返回 */
export interface StudentLearningProfile {
  studentId: string;
  studentName: string;
  studentEmail: string;
  assignments: StudentAssignmentTrack[];
  summary: StudentProfileSummary;
}

/** 课程学生综合得分率概览项 */
export interface CourseStudentOverviewItem {
  studentId: string;
  studentName: string;
  studentEmail: string;
  avgScoreRate: number | null;
  gradedCount: number;
}

/** teacher_get_course_students_overview 返回 */
export interface CourseStudentsOverview {
  students: CourseStudentOverviewItem[];
}
