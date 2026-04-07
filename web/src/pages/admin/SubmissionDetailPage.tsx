import {
  ArrowLeftOutlined,
  CheckCircleFilled,
  CloseCircleFilled,
  LeftOutlined,
  MinusCircleFilled,
  RightOutlined,
} from "@ant-design/icons";
import {
  Button,
  Card,
  Space,
  Spin,
  Tag,
  Typography,
  message,
} from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useParams, useNavigate } from "react-router";
import { useCallback, useEffect, useState } from "react";
import { getGradingSourceTagInfo } from "@/lib/assignmentGrading";
import { getRoleRedirectPath } from "@/lib/profile";
import { adminGetSubmissionDetail } from "@/services/adminAssignments";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage } from "@/lib/utils";
import type {
  AdminSubmissionAnswer,
  AdminSubmissionDetail,
  QuestionType,
  SubmissionStatus,
} from "@/types/assignment";

dayjs.locale("zh-cn");

const TYPE_LABEL: Record<QuestionType, string> = {
  single_choice: "单选题",
  multiple_choice: "多选题",
  true_false: "判断题",
  fill_blank: "填空题",
  short_answer: "简答题",
};

const STATUS_LABEL: Record<SubmissionStatus, { text: string; color: string }> = {
  not_started: { text: "未开始", color: "default" },
  in_progress: { text: "作答中", color: "processing" },
  submitted: { text: "已提交", color: "blue" },
  ai_grading: { text: "AI批改中", color: "processing" },
  auto_graded: { text: "自动判分可复核", color: "geekblue" },
  ai_graded: { text: "AI待复核", color: "orange" },
  graded: { text: "已批改", color: "green" },
};

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

function formatCorrectAnswer(ca: Record<string, unknown> | null, qt: QuestionType): string {
  if (!ca) return "-";
  const val = ca.answer;
  if (val == null) return "-";
  switch (qt) {
    case "multiple_choice":
      return Array.isArray(val) ? val.join(", ") : String(val);
    case "true_false":
      return val === true ? "正确" : "错误";
    case "fill_blank":
      return Array.isArray(val) ? val.join(" | ") : String(val);
    default:
      return String(val);
  }
}

function ScoreIcon({ isCorrect }: { isCorrect: boolean | null }) {
  if (isCorrect === true) return <CheckCircleFilled className="text-green-500" />;
  if (isCorrect === false) return <CloseCircleFilled className="text-red-500" />;
  return <MinusCircleFilled className="text-gray-400" />;
}

export default function AdminSubmissionDetailPage() {
  const navigate = useNavigate();
  const { id: assignmentId, submissionId } = useParams<{
    id: string;
    submissionId: string;
  }>();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [detail, setDetail] = useState<AdminSubmissionDetail | null>(null);
  const [loading, setLoading] = useState(true);

  const canAccess = authInitialized && user?.role === "admin";

  const loadDetail = useCallback(async () => {
    if (!submissionId) return;
    setLoading(true);
    try {
      const data = await adminGetSubmissionDetail(submissionId);
      setDetail(data);
    } catch (error) {
      message.error(toErrorMessage(error, "加载提交详情失败"));
    } finally {
      setLoading(false);
    }
  }, [submissionId]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "admin") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (canAccess && submissionId) void loadDetail();
  }, [canAccess, submissionId, loadDetail]);

  const navigateToSubmission = (sid: string) => {
    navigate(`/admin/assignments/${assignmentId}/submissions/${sid}`, { replace: true });
  };

  if (loading || !canAccess) {
    return <div className="flex h-full items-center justify-center"><Spin size="large" /></div>;
  }

  if (!detail) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4">
        <Typography.Text type="secondary">提交记录不存在</Typography.Text>
        <Button onClick={() => navigate(`/admin/assignments/${assignmentId}`)}>
          返回作业详情
        </Button>
      </div>
    );
  }

  const { submission: sub, answers, navigation } = detail;
  const statusInfo = STATUS_LABEL[sub.status] || { text: sub.status, color: "default" };
  const totalScore = answers.reduce((s, a) => s + (a.score || 0), 0);
  const maxTotalScore = answers.reduce((s, a) => s + a.maxScore, 0);

  return (
    <div className="flex h-full min-h-0 flex-col overflow-y-auto pb-4">
      {/* Header */}
      <div className="mb-3 rounded-lg bg-white px-4 py-3 shadow-sm">
        <div className="flex items-center justify-between">
          <Space>
            <Button
              type="text"
              icon={<ArrowLeftOutlined />}
              onClick={() => navigate(`/admin/assignments/${assignmentId}`)}
            >
              返回作业详情
            </Button>
            <span className="text-lg font-semibold">
              学生作答: {sub.studentName}
            </span>
            <Tag color={statusInfo.color}>{statusInfo.text}</Tag>
          </Space>

          <Space>
            <Button
              icon={<LeftOutlined />}
              disabled={!navigation.prevSubmissionId}
              onClick={() => navigation.prevSubmissionId && navigateToSubmission(navigation.prevSubmissionId)}
            >
              上一个
            </Button>
            <Button
              icon={<RightOutlined />}
              disabled={!navigation.nextSubmissionId}
              onClick={() => navigation.nextSubmissionId && navigateToSubmission(navigation.nextSubmissionId)}
            >
              下一个
            </Button>
          </Space>
        </div>

        <div className="mt-3 flex items-center gap-6 rounded-lg bg-gray-50 px-4 py-3">
          <div>
            <span className="text-sm text-gray-500">得分</span>
            <div className="text-xl font-bold text-indigo-600">
              {sub.totalScore ?? totalScore}
              <span className="text-base font-normal text-gray-400"> / {maxTotalScore}</span>
            </div>
          </div>
          <div>
            <span className="text-sm text-gray-500">提交时间</span>
            <div className="text-sm">
              {sub.submittedAt ? dayjs(sub.submittedAt).format("YYYY-MM-DD HH:mm") : "-"}
            </div>
          </div>
        </div>
      </div>

      {/* Answer cards */}
      <div className="space-y-4">
        {answers.map((ans, idx) => (
          <ReadonlyAnswerCard key={ans.id} index={idx + 1} answer={ans} />
        ))}
      </div>
    </div>
  );
}

// ── 只读答题卡片 ─────────────────────────────────────────

function ReadonlyAnswerCard({
  index,
  answer,
}: {
  index: number;
  answer: AdminSubmissionAnswer;
}) {
  const gradedInfo = getGradingSourceTagInfo({
    gradedBy: answer.gradedBy,
    questionType: answer.questionType,
  });

  return (
    <Card
      size="small"
      className="shadow-sm"
      title={
        <div className="flex items-center gap-2">
          <ScoreIcon isCorrect={answer.isCorrect} />
          <span>
            第 {index} 题 · {TYPE_LABEL[answer.questionType] || answer.questionType}
          </span>
          <Tag color={gradedInfo.color} icon={gradedInfo.icon} className="ml-1">
            {gradedInfo.text}
          </Tag>
          <span className="ml-auto text-base font-semibold">
            {answer.score} / {answer.maxScore}
          </span>
        </div>
      }
    >
      {/* 题目内容 */}
      <div className="mb-3 whitespace-pre-wrap text-sm">{answer.content}</div>

      {/* 选项（选择题/判断题） */}
      {answer.options && answer.options.length > 0 && (
        <div className="mb-3 space-y-1">
          {answer.options.map((opt) => (
            <div key={opt.label} className="text-sm text-gray-600">
              {opt.label}. {opt.text}
            </div>
          ))}
        </div>
      )}

      {/* 学生答案 */}
      <div className="mb-2 rounded bg-blue-50 px-3 py-2">
        <span className="text-xs text-gray-500">学生答案：</span>
        <span className="text-sm">{formatAnswer(answer.answer, answer.questionType)}</span>
      </div>

      {/* 正确答案 */}
      <div className="mb-2 rounded bg-green-50 px-3 py-2">
        <span className="text-xs text-gray-500">正确答案：</span>
        <span className="text-sm">{formatCorrectAnswer(answer.correctAnswer, answer.questionType)}</span>
      </div>

      {/* 解析 */}
      {answer.explanation && (
        <div className="mb-2 rounded bg-gray-50 px-3 py-2">
          <span className="text-xs text-gray-500">解析：</span>
          <span className="text-sm whitespace-pre-wrap">{answer.explanation}</span>
        </div>
      )}

      {/* AI 反馈 */}
      {answer.aiFeedback && (
        <div className="mb-2 rounded bg-cyan-50 px-3 py-2">
          <span className="text-xs text-gray-500">AI 反馈：</span>
          <span className="text-sm whitespace-pre-wrap">{answer.aiFeedback}</span>
        </div>
      )}

      {/* AI 评分明细 */}
      {answer.aiDetail && Object.keys(answer.aiDetail).length > 0 && (
        <AiDetailBlock detail={answer.aiDetail} />
      )}

      {/* 教师评语 */}
      {answer.teacherComment && (
        <div className="rounded bg-yellow-50 px-3 py-2">
          <span className="text-xs text-gray-500">教师评语：</span>
          <span className="text-sm whitespace-pre-wrap">{answer.teacherComment}</span>
        </div>
      )}
    </Card>
  );
}

// ── AI 评分维度展示 ──────────────────────────────────────

function AiDetailBlock({ detail }: { detail: Record<string, unknown> }) {
  const dimensions = detail.dimensions;
  if (!Array.isArray(dimensions) || dimensions.length === 0) return null;

  return (
    <div className="mb-2 rounded bg-cyan-50 px-3 py-2">
      <div className="mb-1 text-xs text-gray-500">AI 评分维度：</div>
      <div className="space-y-1">
        {dimensions.map((dim: Record<string, unknown>, i: number) => (
          <div key={i} className="flex items-center justify-between text-sm">
            <span>{String(dim.name || dim.dimension || `维度${i + 1}`)}</span>
            <span className="font-medium">
              {String(dim.score ?? "-")} / {String(dim.max_score ?? dim.maxScore ?? "-")}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
