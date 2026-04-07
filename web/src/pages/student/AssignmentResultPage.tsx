import {
  ArrowLeftOutlined,
  CheckCircleFilled,
  ClockCircleFilled,
  CloseCircleFilled,
  FileTextFilled,
  RobotOutlined,
} from "@ant-design/icons";
import {
  Button,
  Space,
  Spin,
  Tag,
  message,
} from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useNavigate, useParams } from "react-router";
import { useCallback, useEffect, useRef, useState } from "react";
import QuestionTutorDrawer from "@/components/QuestionTutorDrawer";
import { getRoleRedirectPath } from "@/lib/profile";
import { studentGetResult } from "@/services/studentAssignments";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, QUESTION_TYPE_LABEL } from "@/lib/utils";
import type {
  AnswerResult,
  AssignmentResult,
  QuestionType,
  SubmissionStatus,
} from "@/types/assignment";

dayjs.locale("zh-cn");

const STATUS_LABEL: Record<Exclude<SubmissionStatus, "graded">, { text: string; color: string }> = {
  not_started: { text: "未作答", color: "default" },
  in_progress: { text: "答题中", color: "blue" },
  submitted: { text: "已提交", color: "orange" },
  ai_grading: { text: "AI批改中", color: "orange" },
  auto_graded: { text: "已判分", color: "green" },
  ai_graded: { text: "待复核", color: "cyan" },
};

function getSubmissionStatusLabel(
  status: SubmissionStatus,
  teacherReviewed: boolean
): { text: string; color: string } {
  if (status === "graded") {
    return teacherReviewed
      ? { text: "已复核", color: "green" }
      : { text: "已判分", color: "green" };
  }

  return STATUS_LABEL[status];
}

function shouldHideStudentScore(status: SubmissionStatus): boolean {
  return status === "submitted" || status === "ai_grading" || status === "ai_graded";
}

function isChoiceQuestion(questionType: QuestionType): boolean {
  return questionType === "single_choice" || questionType === "multiple_choice";
}

function formatAnswer(answer: unknown, questionType: QuestionType): string {
  if (answer == null) return "（未作答）";
  const a = answer as Record<string, unknown>;
  const val = a.answer;
  if (val == null) return "（未作答）";

  switch (questionType) {
    case "single_choice":
      return String(val);
    case "multiple_choice":
      return Array.isArray(val) ? val.join(", ") : String(val);
    case "true_false":
      return val === true ? "正确" : val === false ? "错误" : String(val);
    case "fill_blank":
      return Array.isArray(val) ? val.join(" | ") : String(val);
    case "short_answer":
      return String(val);
    default:
      return JSON.stringify(val);
  }
}

function formatCorrectAnswer(
  correctAnswer: Record<string, unknown> | null | undefined,
  questionType: QuestionType
): string {
  if (!correctAnswer) return "-";
  const val = correctAnswer.answer;
  if (val == null) return "-";

  switch (questionType) {
    case "single_choice":
      return String(val);
    case "multiple_choice":
      return Array.isArray(val) ? val.join(", ") : String(val);
    case "true_false":
      return val === true ? "正确" : "错误";
    case "fill_blank":
      return Array.isArray(val) ? val.join(" | ") : String(val);
    case "short_answer":
      return String(val);
    default:
      return JSON.stringify(val);
  }
}

function AnswerStatusTag({
  isCorrect,
  questionType,
  status,
  gradedBy,
}: {
  isCorrect: boolean | null;
  questionType: QuestionType;
  status: SubmissionStatus;
  gradedBy: string;
}) {
  if (questionType === "short_answer") {
    if (status === "submitted" || status === "ai_grading") {
      return (
        <Tag color="processing" icon={<ClockCircleFilled />}>
          AI批改中
        </Tag>
      );
    }

    if (status === "ai_graded") {
      return (
        <Tag color="warning" icon={<ClockCircleFilled />}>
          待复核
        </Tag>
      );
    }

    if (status === "graded" && isCorrect == null && gradedBy !== "teacher") {
      return (
        <Tag color="processing" icon={<FileTextFilled />}>
          已评阅
        </Tag>
      );
    }
  }

  if (isCorrect === true) {
    return (
      <Tag color="success" icon={<CheckCircleFilled />}>
        回答正确
      </Tag>
    );
  }

  if (isCorrect === false) {
    return (
      <Tag color="error" icon={<CloseCircleFilled />}>
        回答有误
      </Tag>
    );
  }

  if (questionType === "short_answer") {
    if (status === "graded") {
      return (
        <Tag color="processing" icon={<FileTextFilled />}>
          已评阅
        </Tag>
      );
    }

    return (
      <Tag color="warning" icon={<ClockCircleFilled />}>
        待复核
      </Tag>
    );
  }

  return (
    <Tag color="default" icon={<ClockCircleFilled />}>
      待判定
    </Tag>
  );
}

export default function StudentAssignmentResultPage() {
  const navigate = useNavigate();
  const { assignmentId } = useParams<{ assignmentId: string }>();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [result, setResult] = useState<AssignmentResult | null>(null);
  const [loading, setLoading] = useState(true);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const canAccess = authInitialized && user?.role === "student";

  const loadResult = useCallback(async () => {
    if (!assignmentId) return;
    setLoading(true);
    try {
      const data = await studentGetResult(assignmentId);
      setResult(data);
    } catch (error) {
      message.error(toErrorMessage(error, "加载成绩失败"));
    } finally {
      setLoading(false);
    }
  }, [assignmentId]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) {
      navigate("/login", { replace: true });
      return;
    }
    if (user.role !== "student") {
      navigate(getRoleRedirectPath(user.role), { replace: true });
    }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (canAccess && assignmentId) void loadResult();
  }, [canAccess, assignmentId, loadResult]);

  // AI 批改中自动轮询（每 8 秒刷新一次，直到状态不再是 submitted / ai_grading）
  const currentStatus = result?.submissionStatus;
  useEffect(() => {
    const needsPoll =
      currentStatus === "submitted" || currentStatus === "ai_grading";

    if (needsPoll && assignmentId) {
      pollRef.current = setInterval(async () => {
        try {
          const data = await studentGetResult(assignmentId);
          setResult(data);
          if (data.submissionStatus !== "submitted" && data.submissionStatus !== "ai_grading") {
            if (pollRef.current) clearInterval(pollRef.current);
          }
        } catch {
          // 轮询失败静默忽略
        }
      }, 8000);
    }
    return () => {
      if (pollRef.current) {
        clearInterval(pollRef.current);
        pollRef.current = null;
      }
    };
  }, [currentStatus, assignmentId]);

  if (loading || !canAccess) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  if (!result) {
    return (
      <div className="flex h-full items-center justify-center text-gray-400">
        成绩不存在或尚未提交
      </div>
    );
  }

  const statusInfo = getSubmissionStatusLabel(result.submissionStatus, result.teacherReviewed);
  const isPolling = result.submissionStatus === "submitted" || result.submissionStatus === "ai_grading";
  const hideScore = shouldHideStudentScore(result.submissionStatus);

  return (
    <div className="flex h-full min-h-0 flex-col overflow-y-auto">
      {/* AI批改中提示 */}
      {isPolling && (
        <div className="mb-3 flex items-center gap-2 rounded-lg bg-cyan-50 border border-cyan-200 px-4 py-3 text-sm text-cyan-700">
          <Spin size="small" />
          <span>AI 正在批改主观题，页面将自动刷新…</span>
        </div>
      )}

      {/* 顶部栏 */}
      <div className="mb-3 rounded-lg bg-white px-4 py-3 shadow-sm">
        <div className="flex items-center justify-between">
          <Space>
            <Button
              type="text"
              icon={<ArrowLeftOutlined />}
              onClick={() => navigate("/student/assignments")}
            >
              返回
            </Button>
            <span className="text-lg font-semibold">{result.title}</span>
            <Tag>{result.courseName}</Tag>
          </Space>
          <Tag color={statusInfo.color}>{statusInfo.text}</Tag>
        </div>

        {/* 成绩概览 */}
        <div className="mt-3 flex items-baseline gap-6 rounded-lg bg-gray-50 px-4 py-3">
          <div>
            <span className="text-sm text-gray-500">得分</span>
            <div className="text-2xl font-bold text-indigo-600">
              {hideScore ? "-" : result.studentScore ?? "-"}{" "}
              <span className="text-base font-normal text-gray-400">
                / {result.totalScore}
              </span>
            </div>
          </div>
          <div>
            <span className="text-sm text-gray-500">提交时间</span>
            <div className="text-sm">
              {result.submittedAt
                ? dayjs(result.submittedAt).format("YYYY-MM-DD HH:mm")
                : "-"}
            </div>
          </div>
        </div>
      </div>

      {/* 答题详情 */}
      <div className="space-y-4 pb-4">
        {result.answers.map((ans, idx) => (
          <AnswerCard key={ans.questionId} index={idx + 1} answer={ans} status={result.submissionStatus} submissionId={result.submissionId} />
        ))}
      </div>
    </div>
  );
}

// ── 答案详情卡片 ─────────────────────────────────────────

function AnswerCard({
  index,
  answer,
  status,
  submissionId,
}: {
  index: number;
  answer: AnswerResult;
  status: SubmissionStatus;
  submissionId: string;
}) {
  const [tutorOpen, setTutorOpen] = useState(false);
  const canUseTutor = status === "graded" || status === "auto_graded";

  // 成绩页在提交后统一展示正确答案和解析；简答题分数仍按状态控制是否隐藏
  const showCorrect = true;
  const suppressPendingShortAnswerState =
    answer.questionType === "short_answer" &&
    (status === "submitted" || status === "ai_grading" || status === "ai_graded");
  const hideScore =
    answer.questionType === "short_answer" &&
    (status === "submitted" || status === "ai_grading" || status === "ai_graded");
  return (
    <div className="rounded-lg bg-white p-4 shadow-sm">
      <div className="mb-2 flex items-center gap-2">
        <Tag color="blue">第 {index} 题</Tag>
        <Tag>{QUESTION_TYPE_LABEL[answer.questionType]}</Tag>
        <Space>
          <span className="font-medium">
            {hideScore ? "-" : answer.score} / {answer.maxScore} 分
          </span>
          <AnswerStatusTag
            isCorrect={answer.isCorrect}
            questionType={answer.questionType}
            status={status}
            gradedBy={answer.gradedBy}
          />
        </Space>
      </div>

      <div className="mb-3 whitespace-pre-wrap text-gray-800">
        {answer.content}
      </div>

      {isChoiceQuestion(answer.questionType) && answer.options && answer.options.length > 0 && (
        <div className="mb-3 rounded bg-white text-sm">
          <div className="space-y-1 text-gray-500">
            {answer.options.map((option) => (
              <div key={option.label}>
                <span className="font-medium">{option.label}. </span>
                <span>{option.text}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="space-y-2 rounded bg-gray-50 p-3 text-sm">
        <div>
          <span className="text-gray-500">你的答案：</span>
          <span
            className={
              suppressPendingShortAnswerState
                ? ""
                : answer.isCorrect === true
                ? "text-green-600"
                : answer.isCorrect === false
                ? "text-red-500"
                : ""
            }
          >
            {formatAnswer(answer.studentAnswer, answer.questionType)}
          </span>
        </div>

        {showCorrect && answer.correctAnswer && (
          <div>
            <span className="text-gray-500">正确答案：</span>
            <span className="text-green-600">
              {formatCorrectAnswer(answer.correctAnswer, answer.questionType)}
            </span>
          </div>
        )}

        {showCorrect && answer.explanation && (
          <div>
            <span className="text-gray-500">解析：</span>
            <span>{answer.explanation}</span>
          </div>
        )}
      </div>

      {/* AI 反馈 */}
      {answer.aiFeedback && (
        <div className="mt-3 rounded border border-cyan-100 bg-cyan-50 p-3 text-sm">
          <div className="mb-1 font-medium text-cyan-700">AI 反馈</div>
          <div className="whitespace-pre-wrap text-gray-700">
            {answer.aiFeedback}
          </div>
        </div>
      )}

      {/* 教师评语 */}
      {answer.teacherComment && (
        <div className="mt-3 rounded border border-green-100 bg-green-50 p-3 text-sm">
          <div className="mb-1 font-medium text-green-700">教师评语</div>
          <div className="whitespace-pre-wrap text-gray-700">
            {answer.teacherComment}
          </div>
        </div>
      )}

      {/* AI 解惑入口 */}
      {canUseTutor && (
        <div className="mt-3 flex justify-end">
          <Button
            type="default"
            icon={<RobotOutlined />}
            onClick={() => setTutorOpen(true)}
          >
            AI 解惑
          </Button>
        </div>
      )}

      <QuestionTutorDrawer
        open={tutorOpen}
        onClose={() => setTutorOpen(false)}
        questionIndex={index}
        questionId={answer.questionId}
        submissionId={submissionId}
        questionType={answer.questionType}
        isCorrect={answer.isCorrect}
      />
    </div>
  );
}

