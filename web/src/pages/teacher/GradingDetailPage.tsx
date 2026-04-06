import {
  ArrowLeftOutlined,
  CheckCircleFilled,
  CheckOutlined,
  CloseCircleFilled,
  MinusCircleFilled,
} from "@ant-design/icons";
import {
  Button,
  Card,
  Input,
  InputNumber,
  Modal,
  Space,
  Spin,
  Tag,
  message,
} from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useParams, useNavigate } from "react-router";
import { useCallback, useEffect, useState } from "react";
import { getGradingSourceTagInfo } from "@/lib/assignmentGrading";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  teacherAcceptAllAiScores,
  teacherFinalizeGrading,
  teacherGetSubmissionDetail,
  teacherGradeAnswer,
} from "@/services/teacherAssignments";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage } from "@/lib/utils";
import type {
  QuestionType,
  SubmissionDetail,
  SubmissionDetailAnswer,
} from "@/types/assignment";

dayjs.locale("zh-cn");

const TYPE_LABEL: Record<QuestionType, string> = {
  single_choice: "单选题",
  multiple_choice: "多选题",
  true_false: "判断题",
  fill_blank: "填空题",
  short_answer: "简答题",
};

const STATUS_LABEL: Record<string, { text: string; color: string }> = {
  submitted: { text: "已提交", color: "orange" },
  ai_grading: { text: "AI批改中", color: "orange" },
  ai_graded: { text: "待复核", color: "cyan" },
  graded: { text: "已复核", color: "green" },
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

export default function TeacherGradingDetailPage() {
  const navigate = useNavigate();
  const { assignmentId, submissionId } = useParams<{
    assignmentId: string;
    submissionId: string;
  }>();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [detail, setDetail] = useState<SubmissionDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);

  // 教师修改的分数/评语缓存
  const [editScores, setEditScores] = useState<Record<string, number>>({});
  const [editComments, setEditComments] = useState<Record<string, string>>({});

  const canAccess = authInitialized && user?.role === "teacher";

  const loadDetail = useCallback(async () => {
    if (!submissionId) return;
    setLoading(true);
    try {
      const data = await teacherGetSubmissionDetail(submissionId);
      setDetail(data);
      // 初始化编辑缓存
      const scores: Record<string, number> = {};
      const comments: Record<string, string> = {};
      for (const ans of data.answers) {
        const answerKey = ans.answerId ?? ans.questionId;
        scores[answerKey] = ans.score;
        comments[answerKey] = ans.teacherComment ?? "";
      }
      setEditScores(scores);
      setEditComments(comments);
    } catch (error) {
      message.error(toErrorMessage(error, "加载提交详情失败"));
    } finally {
      setLoading(false);
    }
  }, [submissionId]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "teacher") navigate(getRoleRedirectPath(user.role), { replace: true });
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (canAccess && submissionId) void loadDetail();
  }, [canAccess, submissionId, loadDetail]);

  // 保存单题评分
  const handleSaveAnswer = useCallback(async (answerId: string) => {
    const score = editScores[answerId];
    const comment = editComments[answerId] || undefined;
    if (score == null) return;
    setBusy(true);
    try {
      await teacherGradeAnswer(answerId, score, comment);
      message.success("已保存");
      await loadDetail();
    } catch (error) {
      message.error(toErrorMessage(error, "保存失败"));
    } finally {
      setBusy(false);
    }
  }, [editScores, editComments, loadDetail]);

  // 一键采纳
  const handleAcceptAll = useCallback(async () => {
    if (!submissionId) return;
    Modal.confirm({
      title: "一键采纳 AI 评分",
      content: "将所有题目的分数设为 AI 评分，确认采纳？",
      okText: "确认采纳",
      cancelText: "取消",
      onOk: async () => {
        setBusy(true);
        try {
          await teacherAcceptAllAiScores(submissionId);
          message.success("已采纳所有 AI 评分");
          await loadDetail();
        } catch (error) {
          message.error(toErrorMessage(error, "采纳失败"));
        } finally {
          setBusy(false);
        }
      },
    });
  }, [submissionId, loadDetail]);

  // 确认复核完成
  const handleFinalize = useCallback(async () => {
    if (!submissionId) return;
    Modal.confirm({
      title: "确认复核完成",
      content: "复核完成后学生将看到完整成绩、正确答案和解析。确认完成？",
      okText: "确认完成",
      cancelText: "取消",
      onOk: async () => {
        setBusy(true);
        try {
          await teacherFinalizeGrading(submissionId);
          message.success("复核已完成");
          await loadDetail();
        } catch (error) {
          message.error(toErrorMessage(error, "确认复核失败"));
        } finally {
          setBusy(false);
        }
      },
    });
  }, [submissionId, loadDetail]);

  if (loading || !canAccess) {
    return <div className="flex h-full items-center justify-center"><Spin size="large" /></div>;
  }

  if (!detail) {
    return <div className="flex h-full items-center justify-center text-gray-400">提交记录不存在</div>;
  }

  const statusInfo = STATUS_LABEL[detail.status] ?? { text: detail.status, color: "default" };
  const isFinalized = detail.status === "graded";
  const isAiGrading = detail.status === "ai_grading" || detail.status === "submitted";
  const currentTotal = Object.values(editScores).reduce((s, v) => s + (v || 0), 0);

  // "一键采纳"仅在有主观题且存在 AI 评分时显示
  const hasSubjective = detail.answers.some(
    (a) => a.questionType === "fill_blank" || a.questionType === "short_answer"
  );
  const hasAiScores = detail.answers.some(
    (a) => a.aiScore != null && a.gradedBy !== "teacher"
  );
  const showAcceptAll = !isFinalized && hasSubjective && hasAiScores;

  return (
    <div className="flex h-full min-h-0 flex-col overflow-y-auto pb-4">
      {/* 顶部信息栏 */}
      <div className="mb-3 rounded-lg bg-white px-4 py-3 shadow-sm">
        <div className="flex items-center justify-between">
          <Space>
            <Button
              type="text"
              icon={<ArrowLeftOutlined />}
              onClick={() => navigate(`/teacher/assignments/${assignmentId}/stats`)}
            >
              返回统计
            </Button>
            <span className="text-lg font-semibold">
              复核: {detail.studentName || detail.studentEmail}
            </span>
            <Tag color={statusInfo.color}>{statusInfo.text}</Tag>
          </Space>
        </div>

        <div className="mt-3 flex items-center gap-6 rounded-lg bg-gray-50 px-4 py-3">
          <div>
            <span className="text-sm text-gray-500">作业</span>
            <div className="text-sm font-medium">{detail.assignmentTitle}</div>
          </div>
          <div>
            <span className="text-sm text-gray-500">当前总分</span>
            <div className="text-xl font-bold text-indigo-600">
              {currentTotal} <span className="text-base font-normal text-gray-400">/ {detail.assignmentTotalScore}</span>
            </div>
          </div>
          <div>
            <span className="text-sm text-gray-500">提交时间</span>
            <div className="text-sm">
              {detail.submittedAt ? dayjs(detail.submittedAt).format("YYYY-MM-DD HH:mm") : "-"}
            </div>
          </div>

          {!isFinalized && (
            <div className="ml-auto flex items-center gap-2">
              {isAiGrading && (
                <Tag color="orange">AI 批改中，请等待完成后再复核</Tag>
              )}
              {showAcceptAll && (
                <Button onClick={handleAcceptAll} disabled={busy || isAiGrading}>
                  一键采纳 AI 评分
                </Button>
              )}
              <Button type="primary" icon={<CheckOutlined />} onClick={handleFinalize} disabled={busy || isAiGrading}>
                确认复核完成
              </Button>
            </div>
          )}
        </div>
      </div>

      {/* 逐题查看 */}
      <div className="space-y-4">
        {detail.answers.map((ans, idx) => {
          const answerKey = ans.answerId ?? ans.questionId;
          // 客观题（单选/多选/判断）仅展示，不可编辑评分
          const editable =
            Boolean(ans.answerId) &&
            (ans.questionType === "fill_blank" || ans.questionType === "short_answer");
          return (
            <AnswerGradeCard
              key={answerKey}
              index={idx + 1}
              answer={ans}
              editable={editable}
              isFinalized={isFinalized}
              busy={busy}
              editScore={editScores[answerKey] ?? ans.score}
              editComment={editComments[answerKey] ?? ""}
              onScoreChange={(v) =>
                setEditScores((prev) => ({ ...prev, [answerKey]: v }))
              }
              onCommentChange={(v) =>
                setEditComments((prev) => ({ ...prev, [answerKey]: v }))
              }
              onSave={() => {
                if (ans.answerId) {
                  void handleSaveAnswer(ans.answerId);
                }
              }}
            />
          );
        })}
      </div>
    </div>
  );
}

// ── 单题复核卡片 ─────────────────────────────────────────

function AnswerGradeCard({
  index,
  answer,
  editable,
  isFinalized,
  busy,
  editScore,
  editComment,
  onScoreChange,
  onCommentChange,
  onSave,
}: {
  index: number;
  answer: SubmissionDetailAnswer;
  editable: boolean;
  isFinalized: boolean;
  busy: boolean;
  editScore: number;
  editComment: string;
  onScoreChange: (v: number) => void;
  onCommentChange: (v: string) => void;
  onSave: () => void;
}) {
  const gradedInfo = getGradingSourceTagInfo({
    gradedBy: answer.gradedBy,
    questionType: answer.questionType,
  });
  return (
    <Card size="small" className="shadow-sm">
      <div className="mb-2 flex items-center gap-2">
        <Tag color="blue">第 {index} 题</Tag>
        <Tag>{TYPE_LABEL[answer.questionType]}</Tag>
        <ScoreIcon isCorrect={answer.isCorrect} />
        <span className="text-sm text-gray-500">
          {answer.score} / {answer.maxScore} 分
          {answer.aiScore != null && answer.aiScore !== answer.score && (
            <span className="ml-1 text-cyan-600">（AI: {answer.aiScore}）</span>
          )}
        </span>
        <Tag className="ml-auto" color={gradedInfo.color} icon={gradedInfo.icon}>
          {gradedInfo.text}
        </Tag>
      </div>

      {/* 题目内容 */}
      <div className="mb-3 whitespace-pre-wrap text-gray-800">{answer.content}</div>

      {/* 答案对比 */}
      <div className="space-y-1 rounded bg-gray-50 p-3 text-sm">
        <div>
          <span className="text-gray-500">学生答案：</span>
          <span className={answer.isCorrect === true ? "text-green-600" : answer.isCorrect === false ? "text-red-500" : ""}>
            {formatAnswer(answer.studentAnswer, answer.questionType)}
          </span>
        </div>
        <div>
          <span className="text-gray-500">正确答案：</span>
          <span className="text-green-600">
            {formatCorrectAnswer(answer.correctAnswer, answer.questionType)}
          </span>
        </div>
        {answer.explanation && (
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
          <div className="whitespace-pre-wrap text-gray-700">{answer.aiFeedback}</div>
        </div>
      )}

      {/* AI 评分明细（简答题） */}
      {answer.aiDetail && answer.questionType === "short_answer" && (
        <AiBreakdown detail={answer.aiDetail} />
      )}

      {/* 教师评分区域（仅填空题和简答题可编辑） */}
      {editable && !isFinalized && (
        <div className="mt-3 flex items-end gap-4 rounded border border-indigo-100 bg-indigo-50 p-3">
          <div>
            <div className="mb-1 text-xs text-gray-500">教师评分</div>
            <InputNumber
              min={0}
              max={answer.maxScore}
              step={0.5}
              value={editScore}
              onChange={(v) => onScoreChange(v ?? 0)}
              addonAfter={`/ ${answer.maxScore}`}
              size="small"
              className="w-32"
            />
          </div>
          <div className="flex-1">
            <div className="mb-1 text-xs text-gray-500">教师评语（可选）</div>
            <Input.TextArea
              rows={1}
              autoSize={{ minRows: 1, maxRows: 3 }}
              value={editComment}
              onChange={(e) => onCommentChange(e.target.value)}
              placeholder="输入评语..."
              size="small"
            />
          </div>
          <Button
            type="primary"
            size="small"
            onClick={onSave}
            loading={busy}
          >
            保存
          </Button>
        </div>
      )}

      {/* 已复核时显示教师评语 */}
      {isFinalized && answer.teacherComment && (
        <div className="mt-3 rounded border border-green-100 bg-green-50 p-3 text-sm">
          <div className="mb-1 font-medium text-green-700">教师评语</div>
          <div className="whitespace-pre-wrap text-gray-700">{answer.teacherComment}</div>
        </div>
      )}
    </Card>
  );
}

// ── AI 简答题评分维度 ────────────────────────────────────

function AiBreakdown({ detail }: { detail: Record<string, unknown> }) {
  const breakdown = detail.breakdown as Record<string, { score: number; max: number; comment: string }> | undefined;
  if (!breakdown) return null;

  const dims = [
    { key: "knowledge_coverage", label: "知识覆盖" },
    { key: "accuracy", label: "表述准确性" },
    { key: "logic", label: "逻辑完整性" },
    { key: "language", label: "语言规范性" },
  ];

  return (
    <div className="mt-2 rounded border border-cyan-100 bg-cyan-50 p-3 text-sm">
      <div className="mb-1 font-medium text-cyan-700">AI 评分明细</div>
      <div className="space-y-1">
        {dims.map(({ key, label }) => {
          const d = breakdown[key];
          if (!d) return null;
          return (
            <div key={key} className="flex items-center gap-2">
              <span className="w-20 text-gray-500">{label}:</span>
              <span className="font-medium">{d.score} / {d.max}</span>
              {d.comment && <span className="text-gray-400">— {d.comment}</span>}
            </div>
          );
        })}
      </div>
    </div>
  );
}


