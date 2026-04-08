import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router";
import {
  Button,
  Card,
  Empty,
  Select,
  Space,
  Spin,
  Table,
  Tag,
  Tooltip,
  Typography,
  message,
  Collapse,
  Progress,
} from "antd";
import type { TableColumnsType } from "antd";
import { ReloadOutlined, RobotOutlined } from "@ant-design/icons";
import { Pie } from "@ant-design/charts";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { useAuthStore } from "@/store/authStore";
import { getRoleRedirectPath } from "@/lib/profile";
import { toErrorMessage } from "@/lib/utils";
import { teacherListCourses } from "@/services/teacherCourses";
import { teacherGetCourseAnalytics, teacherGetErrorQuestions, streamErrorAnalysis } from "@/services/teacherAnalytics";
import type { TeacherCourse } from "@/types/course";
import type {
  CourseAnalytics,
  ErrorQuestionItem,
  ErrorQuestionListResult,
  CommonWrongAnswer,
  QuestionOption,
  QuestionType,
} from "@/types/assignment";

const { Title, Text, Paragraph } = Typography;

const QUESTION_TYPE_LABEL: Record<string, string> = {
  single_choice: "单选",
  multiple_choice: "多选",
  true_false: "判断",
  fill_blank: "填空",
  short_answer: "简答",
};

function formatAnswer(answer: unknown, questionType: QuestionType): string {
  if (answer == null) return "-";
  const obj = (typeof answer === "object" && answer !== null) ? answer as Record<string, unknown> : null;
  const val = obj?.answer ?? answer;
  if (val == null) return "ï¼æªä½ç­ï¼";
  switch (questionType) {
    case "single_choice":
      return String(val);
    case "multiple_choice":
      return Array.isArray(val) ? val.join(", ") : String(val);
    case "true_false":
      return val === true ? "æ­£ç¡®" : val === false ? "éè¯¯" : String(val);
    case "fill_blank":
      return Array.isArray(val) ? val.join(" | ") : String(val);
    case "short_answer":
      return String(val);
    default:
      return String(val);
  }
}

function isChoiceQuestion(type: QuestionType): boolean {
  return type === "single_choice" || type === "multiple_choice";
}

export default function ErrorQuestionsPage() {
  const navigate = useNavigate();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [courses, setCourses] = useState<TeacherCourse[]>([]);
  const [selectedCourseId, setSelectedCourseId] = useState<string | null>(null);
  const [loadingCourses, setLoadingCourses] = useState(true);

  const [analytics, setAnalytics] = useState<CourseAnalytics | null>(null);
  const [selectedAssignmentId, setSelectedAssignmentId] = useState<string | undefined>(undefined);

  const [result, setResult] = useState<ErrorQuestionListResult | null>(null);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);

  // ── AI 错因分析 ────────────────────────────────────────
  const [aiAnalysisMap, setAiAnalysisMap] = useState<Record<string, string>>({});
  const [aiLoadingId, setAiLoadingId] = useState<string | null>(null);
  const aiAbortRef = useRef<AbortController | null>(null);

  const handleAiErrorAnalysis = useCallback(async (record: ErrorQuestionItem) => {
    aiAbortRef.current?.abort();
    const controller = new AbortController();
    aiAbortRef.current = controller;
    const key = record.questionId;
    setAiLoadingId(key);
    setAiAnalysisMap((prev) => ({ ...prev, [key]: "" }));
    let acc = "";
    try {
      await streamErrorAnalysis(
        record.assignmentId,
        record.questionId,
        (token) => {
          acc += token;
          setAiAnalysisMap((prev) => ({ ...prev, [key]: acc }));
        },
        controller.signal,
      );
    } catch (e) {
      if (!controller.signal.aborted) void message.error(toErrorMessage(e, "AI 分析失败"));
    } finally {
      setAiLoadingId(null);
    }
  }, []);

  // ── Auth guard ─────────────────────────────────────────
  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "teacher") navigate(getRoleRedirectPath(user.role), { replace: true });
  }, [authInitialized, navigate, user]);

  // ── 加载课程 ───────────────────────────────────────────
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const list = await teacherListCourses();
        if (cancelled) return;
        setCourses(list);
        if (list.length > 0) setSelectedCourseId(list[0].id);
      } catch (e) {
        if (!cancelled) void message.error(toErrorMessage(e, "加载课程失败"));
      } finally {
        if (!cancelled) setLoadingCourses(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  // ── 加载课程分析（获取作业列表用于筛选） ───────────────
  useEffect(() => {
    if (!selectedCourseId) return;
    let cancelled = false;
    void (async () => {
      try {
        const a = await teacherGetCourseAnalytics(selectedCourseId);
        if (!cancelled) setAnalytics(a);
      } catch {
        // ignore
      }
    })();
    return () => { cancelled = true; };
  }, [selectedCourseId]);

  // ── 加载错题 ───────────────────────────────────────────
  const loadErrors = useCallback(
    async (courseId: string, assignmentId?: string, p = 1) => {
      setLoading(true);
      try {
        const data = await teacherGetErrorQuestions(courseId, {
          assignmentId,
          page: p,
          pageSize: 20,
        });
        setResult(data);
        setPage(p);
      } catch (e) {
        void message.error(toErrorMessage(e, "加载错题列表失败"));
      } finally {
        setLoading(false);
      }
    },
    []
  );

  useEffect(() => {
    if (selectedCourseId) void loadErrors(selectedCourseId, selectedAssignmentId, 1);
  }, [selectedCourseId, selectedAssignmentId, loadErrors]);

  // ── 列定义 ─────────────────────────────────────────────
  const columns: TableColumnsType<ErrorQuestionItem> = [
    {
      title: "来源作业",
      dataIndex: "assignmentTitle",
      width: 160,
      ellipsis: true,
    },
    {
      title: "题号",
      dataIndex: "sortOrder",
      width: 60,
      render: (v: number) => `第${v}题`,
    },
    {
      title: "题型",
      dataIndex: "questionType",
      width: 70,
      render: (v: string) => <Tag>{QUESTION_TYPE_LABEL[v] ?? v}</Tag>,
    },
    {
      title: "题目",
      dataIndex: "content",
      ellipsis: true,
      render: (v: string) => (
        <Tooltip title={v}>
          <span>{v.length > 50 ? v.slice(0, 50) + "…" : v}</span>
        </Tooltip>
      ),
    },
    {
      title: "错误率",
      dataIndex: "errorRate",
      width: 100,
      sorter: (a, b) => a.errorRate - b.errorRate,
      defaultSortOrder: "descend",
      render: (v: number) => (
        <span style={{ color: v >= 50 ? "#ef4444" : v >= 30 ? "#f59e0b" : "#10b981", fontWeight: 600 }}>
          {v}%
        </span>
      ),
    },
    {
      title: "错误/总答",
      key: "ratio",
      width: 90,
      render: (_, r) => `${r.wrongCount}/${r.totalAnswers}`,
    },
  ];

  // ── 展开行 — 错误答案分布 ──────────────────────────────
  const expandedRowRender = (record: ErrorQuestionItem) => {
    const pieData = record.commonWrongAnswers.map((a) => ({
      type: formatAnswer(a.answer, record.questionType),
      value: a.count,
    }));

    return (
      <div className="flex flex-col gap-3 p-2">
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          {/* 左：题目详情 */}
          <div>
            <Text strong>题目内容</Text>
            <Paragraph style={{ marginTop: 4 }}>{record.content}</Paragraph>
            {isChoiceQuestion(record.questionType) && record.options && record.options.length > 0 && (
              <div className="mb-3 rounded bg-gray-50 p-2 text-sm">
                <div className="space-y-1 text-gray-600">
                  {record.options.map((option: QuestionOption) => (
                    <div key={option.label}>
                      <span className="font-medium">{option.label}. </span>
                      <span>{option.text}</span>
                    </div>
                  ))}
                </div>
              </div>
            )}
            <Text strong>正确答案</Text>
            <Paragraph style={{ marginTop: 4 }}>{formatAnswer(record.correctAnswer, record.questionType)}</Paragraph>
            {record.explanation && (
              <>
                <Text strong>解析</Text>
                <Paragraph style={{ marginTop: 4 }}>{record.explanation}</Paragraph>
              </>
            )}
          </div>

          {/* 右：错误答案分布 */}
          <div>
            <Text strong>常见错误答案分布</Text>
            {pieData.length > 0 ? (
              <Pie
                data={pieData}
                angleField="value"
                colorField="type"
                height={180}
                innerRadius={0.5}
                label={{
                  text: "type",
                  position: "outside",
                }}
                legend={{ position: "bottom" }}
              />
            ) : (
              <Empty description="无错误答案数据" />
            )}
          </div>
        </div>

        {/* AI 错因分析 */}
        <Card
          size="small"
          style={{ marginTop: 12 }}
          title="AI 错因分析"
          extra={
            <Space>
              {aiLoadingId === record.questionId && (
                <Button size="small" danger onClick={() => aiAbortRef.current?.abort()}>
                  停止
                </Button>
              )}
              <Button
                type="primary"
                size="small"
                icon={<RobotOutlined />}
                loading={aiLoadingId === record.questionId}
                onClick={() => void handleAiErrorAnalysis(record)}
              >
                {aiAnalysisMap[record.questionId] ? "重新分析" : "AI 分析"}
              </Button>
            </Space>
          }
        >
          {aiAnalysisMap[record.questionId] ? (
            <div className="prose prose-sm max-w-none">
              <ReactMarkdown remarkPlugins={[remarkGfm]}>
                {aiAnalysisMap[record.questionId]}
              </ReactMarkdown>
            </div>
          ) : (
            <Empty description="点击按钮生成 AI 错因分析" image={Empty.PRESENTED_IMAGE_SIMPLE} />
          )}
        </Card>
      </div>
    );
  };

  // ── 渲染 ──────────────────────────────────────────────

  if (!authInitialized || loadingCourses) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  if (courses.length === 0) {
    return (
      <div className="flex h-full items-center justify-center">
        <Empty description="暂无课程" />
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col gap-4 overflow-y-auto pb-4">
      {/* 顶栏 */}
      <div className="flex items-center justify-between">
        <Space>
          <Select
            value={selectedCourseId}
            onChange={(v) => { setSelectedCourseId(v); setSelectedAssignmentId(undefined); }}
            style={{ width: 200 }}
            options={courses.map((c) => ({ label: c.name, value: c.id }))}
          />
          <Select
            value={selectedAssignmentId}
            onChange={setSelectedAssignmentId}
            style={{ width: 220 }}
            allowClear
            placeholder="全部作业"
            options={
              analytics?.assignments.map((a) => ({
                label: a.title,
                value: a.id,
              })) ?? []
            }
          />
        </Space>
        <Button
          icon={<ReloadOutlined />}
          onClick={() => selectedCourseId && void loadErrors(selectedCourseId, selectedAssignmentId, page)}
        >
          刷新
        </Button>
      </div>

      {/* 统计 */}
      {result && (
        <Text type="secondary">
          共 {result.total} 道错题（按错误率降序排列）
        </Text>
      )}

      {/* 错题列表 */}
      <Table<ErrorQuestionItem>
        dataSource={result?.items ?? []}
        columns={columns}
        rowKey="questionId"
        loading={loading}
        size="small"
        expandable={{
          expandedRowRender,
          expandRowByClick: true,
        }}
        pagination={{
          current: page,
          pageSize: 20,
          total: result?.total ?? 0,
          showSizeChanger: false,
          onChange: (p) => selectedCourseId && void loadErrors(selectedCourseId, selectedAssignmentId, p),
        }}
      />
    </div>
  );
}
