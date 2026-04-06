import {
  ArrowLeftOutlined,
  CheckCircleOutlined,
  SaveOutlined,
} from "@ant-design/icons";
import {
  Button,
  Checkbox,
  Input,
  Modal,
  Radio,
  Space,
  Spin,
  Tag,
  message,
} from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useNavigate, useParams } from "react-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  studentGetAssignment,
  studentSaveAnswers,
  studentStartSubmission,
  studentSubmit,
  triggerAiGrading,
} from "@/services/studentAssignments";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, QUESTION_TYPE_LABEL } from "@/lib/utils";
import type {
  QuestionType,
  SavedAnswer,
  StudentAssignmentDetail,
  StudentQuestion,
} from "@/types/assignment";

dayjs.locale("zh-cn");

const { TextArea } = Input;

// ── localStorage 缓存 ───────────────────────────────────

function getLsKey(assignmentId: string) {
  return `student_answers_${assignmentId}`;
}

function saveLs(assignmentId: string, answers: Record<string, unknown>) {
  try {
    localStorage.setItem(getLsKey(assignmentId), JSON.stringify(answers));
  } catch {
    // ignore
  }
}

function loadLs(assignmentId: string): Record<string, unknown> {
  try {
    const raw = localStorage.getItem(getLsKey(assignmentId));
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

function clearLs(assignmentId: string) {
  try {
    localStorage.removeItem(getLsKey(assignmentId));
  } catch {
    // ignore
  }
}

/** 判断某题是否已实质性作答（排除空字符串、空数组等无效值） */
function isAnswered(val: unknown): boolean {
  if (val == null) return false;
  if (typeof val === "string") return val.trim().length > 0;
  if (typeof val === "boolean") return true;
  if (Array.isArray(val)) return val.some((v) => typeof v === "string" ? v.trim().length > 0 : v != null);
  if (typeof val === "object") {
    const inner = (val as Record<string, unknown>).answer;
    return isAnswered(inner);
  }
  return true;
}

// ── 组件 ─────────────────────────────────────────────────

export default function StudentAssignmentAnswerPage() {
  const navigate = useNavigate();
  const { assignmentId } = useParams<{ assignmentId: string }>();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [detail, setDetail] = useState<StudentAssignmentDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [submissionId, setSubmissionId] = useState<string | null>(null);
  const [answers, setAnswers] = useState<Record<string, unknown>>({});
  const [saving, setSaving] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  const saveTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const answersRef = useRef<Record<string, unknown>>({});

  const canAccess = authInitialized && user?.role === "student";
  const isReadonly =
    detail?.submissionStatus != null &&
    !["not_started", "in_progress"].includes(detail.submissionStatus);

  // 加载作业详情
  const loadDetail = useCallback(async () => {
    if (!assignmentId) return;
    setLoading(true);
    try {
      const data = await studentGetAssignment(assignmentId);

      // 已截止/已关闭 且 未提交过的作业，不允许继续答题
      const isPastDeadline = data.deadline && dayjs(data.deadline).isBefore(dayjs());
      const canEdit = data.submissionStatus === "not_started" || data.submissionStatus === "in_progress";
      if (canEdit && (data.status === "closed" || isPastDeadline)) {
        message.warning("作业已截止，无法继续答题");
        navigate("/student/assignments", { replace: true });
        return;
      }
      // 已提交的作业跳转到结果页
      if (!canEdit) {
        navigate(`/student/assignments/${assignmentId}/result`, { replace: true });
        return;
      }

      setDetail(data);

      // 恢复答案：服务端优先 > localStorage 补充
      const serverAnswers: Record<string, unknown> = {};
      for (const sa of data.savedAnswers) {
        serverAnswers[sa.questionId] = sa.answer;
      }
      const lsAnswers = loadLs(assignmentId);
      const merged = { ...lsAnswers, ...serverAnswers };
      setAnswers(merged);
      answersRef.current = merged;

      // 创建/恢复提交记录
      if (
        data.status === "published" &&
        (data.submissionStatus === "not_started" ||
          data.submissionStatus === "in_progress")
      ) {
        const sub = await studentStartSubmission(assignmentId);
        setSubmissionId(sub.submissionId);
      } else if (data.submissionId) {
        setSubmissionId(data.submissionId);
      }
    } catch (error) {
      message.error(toErrorMessage(error, "加载作业失败"));
    } finally {
      setLoading(false);
    }
  }, [assignmentId, navigate]);

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
    if (canAccess && assignmentId) void loadDetail();
  }, [canAccess, assignmentId, loadDetail]);

  // 定时自动保存（每 30 秒），使用 answersRef 避免因 answers 变化重建定时器
  useEffect(() => {
    if (!submissionId || isReadonly) return;
    saveTimerRef.current = setInterval(async () => {
      if (!detail) return;
      const payload: SavedAnswer[] = Object.entries(answersRef.current).map(
        ([questionId, answer]) => ({ questionId, answer })
      );
      if (payload.length === 0) return;
      try {
        await studentSaveAnswers(submissionId, payload);
      } catch {
        // 静默保存不弹错误
      }
    }, 30000);

    return () => {
      if (saveTimerRef.current) clearInterval(saveTimerRef.current);
    };
  }, [submissionId, isReadonly, detail]);

  // 更新答案
  const updateAnswer = useCallback(
    (questionId: string, value: unknown) => {
      setAnswers((prev) => {
        const next = { ...prev, [questionId]: value };
        answersRef.current = next;
        if (assignmentId) saveLs(assignmentId, next);
        return next;
      });
    },
    [assignmentId]
  );

  // 保存草稿
  const handleSaveDraft = useCallback(
    async (silent = false) => {
      if (!submissionId || !detail) return;
      const payload: SavedAnswer[] = Object.entries(answersRef.current).map(
        ([questionId, answer]) => ({
          questionId,
          answer,
        })
      );

      if (payload.length === 0) return;

      if (!silent) setSaving(true);
      try {
        await studentSaveAnswers(submissionId, payload);
        if (!silent) message.success("草稿已保存");
      } catch (error) {
        if (!silent)
          message.error(toErrorMessage(error, "保存草稿失败"));
      } finally {
        if (!silent) setSaving(false);
      }
    },
    [submissionId, detail]
  );

  // 提交作业
  const handleSubmit = useCallback(async () => {
    if (!submissionId || !detail || !assignmentId) return;

    // 先保存草稿
    const payload: SavedAnswer[] = Object.entries(answers).map(
      ([questionId, answer]) => ({
        questionId,
        answer,
      })
    );
    if (payload.length > 0) {
      try {
        await studentSaveAnswers(submissionId, payload);
      } catch (error) {
        message.error(toErrorMessage(error, "保存答案失败"));
        return;
      }
    }

    // 统计未答题数量
    const totalQuestions = detail.questions.length;
    const answeredCount = detail.questions.filter(
      (q) => isAnswered(answers[q.id])
    ).length;
    const unanswered = totalQuestions - answeredCount;

    const confirmContent =
      unanswered > 0
        ? `你还有 ${unanswered} 道题未作答，确定提交吗？提交后不可修改。`
        : "确定提交作业吗？提交后不可修改。";

    Modal.confirm({
      title: "提交作业",
      content: confirmContent,
      okText: "确定提交",
      cancelText: "继续答题",
      onOk: async () => {
        setSubmitting(true);
        try {
          const result = await studentSubmit(submissionId);
          clearLs(assignmentId);
          message.success(
            `作业已提交！客观题得分 ${result.autoScore} 分`
          );
          // 仅存在待 AI 处理的简答题时触发异步批改
          if (result.hasSubjective) {
            void triggerAiGrading(submissionId);
          }
          navigate(`/student/assignments/${assignmentId}/result`);
        } catch (error) {
          message.error(toErrorMessage(error, "提交作业失败"));
        } finally {
          setSubmitting(false);
        }
      },
    });
  }, [submissionId, detail, assignmentId, answers, navigate]);

  // 答题统计
  const answerStats = useMemo(() => {
    if (!detail) return { answered: 0, total: 0 };
    const total = detail.questions.length;
    const answered = detail.questions.filter(
      (q) => isAnswered(answers[q.id])
    ).length;
    return { answered, total };
  }, [detail, answers]);

  // 截止时间提示
  const deadlineInfo = useMemo(() => {
    if (!detail?.deadline) return null;
    const d = dayjs(detail.deadline);
    if (!d.isValid()) return null;
    const now = dayjs();
    if (d.isBefore(now)) return { text: "已截止", urgent: true };
    const diffHours = d.diff(now, "hour");
    if (diffHours < 1) return { text: `剩余 ${d.diff(now, "minute")} 分钟`, urgent: true };
    if (diffHours < 24) return { text: `剩余 ${diffHours} 小时`, urgent: true };
    return { text: d.format("YYYY-MM-DD HH:mm"), urgent: false };
  }, [detail]);

  if (loading || !canAccess) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  if (!detail) {
    return (
      <div className="flex h-full items-center justify-center text-gray-400">
        作业不存在或无权查看
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col">
      {/* 顶部栏 */}
      <div className="mb-3 flex items-center justify-between rounded-lg bg-white px-4 py-3 shadow-sm">
        <Space>
          <Button
            type="text"
            icon={<ArrowLeftOutlined />}
            onClick={() => navigate("/student/assignments")}
          >
            返回
          </Button>
          <span className="text-lg font-semibold">{detail.title}</span>
        </Space>
        <Space>
          {deadlineInfo && (
            <Tag color={deadlineInfo.urgent ? "red" : "blue"}>
              截止: {deadlineInfo.text}
            </Tag>
          )}
          <Tag>总分 {detail.totalScore}</Tag>
        </Space>
      </div>

      {/* 主内容区 */}
      <div className="flex flex-1 min-h-0 gap-4">
        {/* 左侧答题区 */}
        <div className="flex-1 min-h-0 overflow-y-auto rounded-lg bg-white p-4 shadow-sm">
          {detail.description && (
            <div className="mb-4 rounded bg-blue-50 px-3 py-2 text-sm text-gray-600">
              {detail.description}
            </div>
          )}

          {detail.questions.map((q, idx) => (
            <QuestionCard
              key={q.id}
              index={idx + 1}
              question={q}
              answer={answers[q.id]}
              readonly={isReadonly}
              onAnswer={(value) => updateAnswer(q.id, value)}
            />
          ))}
        </div>

        {/* 右侧导航面板 */}
        <div className="w-52 shrink-0 rounded-lg bg-white p-4 shadow-sm">
          <div className="mb-3 text-sm font-medium text-gray-500">
            题目导航
          </div>
          <div className="flex flex-wrap gap-2">
            {detail.questions.map((q, idx) => {
              const hasAnswer = isAnswered(answers[q.id]);
              return (
                <button
                  key={q.id}
                  type="button"
                  className={`h-8 w-8 rounded text-sm font-medium transition-colors ${
                    hasAnswer
                      ? "bg-indigo-500 text-white"
                      : "bg-gray-100 text-gray-500 hover:bg-gray-200"
                  }`}
                  onClick={() => {
                    document
                      .getElementById(`question-${q.id}`)
                      ?.scrollIntoView({ behavior: "smooth", block: "center" });
                  }}
                >
                  {idx + 1}
                </button>
              );
            })}
          </div>

          <div className="mt-4 border-t pt-3 text-sm text-gray-500">
            <div className="flex items-center gap-2 mb-1">
              <span className="inline-block h-3 w-3 rounded bg-indigo-500" />
              已答
            </div>
            <div className="flex items-center gap-2">
              <span className="inline-block h-3 w-3 rounded bg-gray-100" />
              未答
            </div>
            <div className="mt-3 font-medium">
              已答: {answerStats.answered} / {answerStats.total}
            </div>
          </div>
        </div>
      </div>

      {/* 底部操作栏 */}
      {!isReadonly && (
        <div className="mt-3 flex items-center justify-center gap-4 rounded-lg bg-white px-4 py-3 shadow-sm">
          <Button
            icon={<SaveOutlined />}
            loading={saving}
            onClick={() => void handleSaveDraft(false)}
          >
            保存草稿
          </Button>
          <Button
            type="primary"
            icon={<CheckCircleOutlined />}
            loading={submitting}
            onClick={() => void handleSubmit()}
          >
            提交作业
          </Button>
        </div>
      )}
    </div>
  );
}

// ── 题目卡片 ─────────────────────────────────────────────

function QuestionCard({
  index,
  question,
  answer,
  readonly,
  onAnswer,
}: {
  index: number;
  question: StudentQuestion;
  answer: unknown;
  readonly: boolean;
  onAnswer: (value: unknown) => void;
}) {
  return (
    <div
      id={`question-${question.id}`}
      className="mb-6 rounded-lg border border-gray-100 p-4"
    >
      <div className="mb-3 flex items-center gap-2">
        <Tag color="blue">
          第 {index} 题
        </Tag>
        <Tag>{QUESTION_TYPE_LABEL[question.questionType]}</Tag>
        <span className="text-sm text-gray-400">{question.score} 分</span>
      </div>
      <div className="mb-3 whitespace-pre-wrap text-gray-800">
        {question.content}
      </div>

      {question.questionType === "single_choice" && (
        <SingleChoiceInput
          options={question.options ?? []}
          value={answer as { answer: string } | undefined}
          readonly={readonly}
          onChange={onAnswer}
        />
      )}
      {question.questionType === "multiple_choice" && (
        <MultipleChoiceInput
          options={question.options ?? []}
          value={answer as { answer: string[] } | undefined}
          readonly={readonly}
          onChange={onAnswer}
        />
      )}
      {question.questionType === "true_false" && (
        <TrueFalseInput
          value={answer as { answer: boolean } | undefined}
          readonly={readonly}
          onChange={onAnswer}
        />
      )}
      {question.questionType === "fill_blank" && (
        <FillBlankInput
          content={question.content}
          value={answer as { answer: string[] } | undefined}
          readonly={readonly}
          onChange={onAnswer}
        />
      )}
      {question.questionType === "short_answer" && (
        <ShortAnswerInput
          value={answer as { answer: string } | undefined}
          readonly={readonly}
          onChange={onAnswer}
        />
      )}
    </div>
  );
}

// ── 各题型输入组件 ───────────────────────────────────────

function SingleChoiceInput({
  options,
  value,
  readonly,
  onChange,
}: {
  options: { label: string; text: string }[];
  value: { answer: string } | undefined;
  readonly: boolean;
  onChange: (value: unknown) => void;
}) {
  return (
    <Radio.Group
      value={value?.answer}
      disabled={readonly}
      onChange={(e) => onChange({ answer: e.target.value })}
    >
      <Space direction="vertical">
        {options.map((opt) => (
          <Radio key={opt.label} value={opt.label}>
            {opt.label}. {opt.text}
          </Radio>
        ))}
      </Space>
    </Radio.Group>
  );
}

function MultipleChoiceInput({
  options,
  value,
  readonly,
  onChange,
}: {
  options: { label: string; text: string }[];
  value: { answer: string[] } | undefined;
  readonly: boolean;
  onChange: (value: unknown) => void;
}) {
  const selected = value?.answer ?? [];
  return (
    <Checkbox.Group
      value={selected}
      disabled={readonly}
      onChange={(checked) => onChange({ answer: checked as string[] })}
    >
      <Space direction="vertical">
        {options.map((opt) => (
          <Checkbox key={opt.label} value={opt.label}>
            {opt.label}. {opt.text}
          </Checkbox>
        ))}
      </Space>
    </Checkbox.Group>
  );
}

function TrueFalseInput({
  value,
  readonly,
  onChange,
}: {
  value: { answer: boolean } | undefined;
  readonly: boolean;
  onChange: (value: unknown) => void;
}) {
  return (
    <Radio.Group
      value={value?.answer}
      disabled={readonly}
      onChange={(e) => onChange({ answer: e.target.value })}
    >
      <Space>
        <Radio value={true}>正确</Radio>
        <Radio value={false}>错误</Radio>
      </Space>
    </Radio.Group>
  );
}

function FillBlankInput({
  content,
  value,
  readonly,
  onChange,
}: {
  content: string;
  value: { answer: string[] } | undefined;
  readonly: boolean;
  onChange: (value: unknown) => void;
}) {
  // 通过 ___ 或 ____（三个以上下划线）检测空位数量
  const blankCount = Math.max((content.match(/_{3,}/g) || []).length, 1);
  const current = value?.answer ?? Array(blankCount).fill("");

  const updateBlank = (idx: number, text: string) => {
    const next = [...current];
    next[idx] = text;
    onChange({ answer: next });
  };

  return (
    <Space direction="vertical" className="w-full">
      {Array.from({ length: blankCount }, (_, i) => (
        <Input
          key={i}
          placeholder={`第 ${i + 1} 空`}
          value={current[i] || ""}
          disabled={readonly}
          onChange={(e) => updateBlank(i, e.target.value)}
          className="max-w-md"
        />
      ))}
    </Space>
  );
}

function ShortAnswerInput({
  value,
  readonly,
  onChange,
}: {
  value: { answer: string } | undefined;
  readonly: boolean;
  onChange: (value: unknown) => void;
}) {
  return (
    <TextArea
      rows={4}
      placeholder="请输入你的回答"
      value={value?.answer ?? ""}
      disabled={readonly}
      onChange={(e) => onChange({ answer: e.target.value })}
      className="max-w-2xl"
    />
  );
}
