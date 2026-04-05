import {
  ArrowLeftOutlined,
  DeleteOutlined,
  PlusOutlined,
} from "@ant-design/icons";
import {
  Button,
  Card,
  DatePicker,
  Form,
  Input,
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
import QuestionEditor, { formatAnswer } from "@/components/assignments/QuestionEditor";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  teacherGetAssignmentDetail,
  teacherPublishAssignment,
  teacherSaveQuestions,
  teacherUpdateAssignment,
} from "@/services/teacherAssignments";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage } from "@/lib/utils";
import type {
  AssignmentDetail,
  Question,
  QuestionType,
} from "@/types/assignment";

dayjs.locale("zh-cn");
const { TextArea } = Input;

const TYPE_LABELS: Record<QuestionType, string> = {
  single_choice: "单选题",
  multiple_choice: "多选题",
  fill_blank: "填空题",
  true_false: "判断题",
  short_answer: "简答题",
};

interface BasicFormValues {
  title: string;
  description?: string;
  deadline?: dayjs.Dayjs | null;
}

export default function EditAssignmentPage() {
  const navigate = useNavigate();
  const params = useParams();
  const assignmentId = params.assignmentId as string;
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [detail, setDetail] = useState<AssignmentDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [questions, setQuestions] = useState<Question[]>([]);
  const [editingIndex, setEditingIndex] = useState<number | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [form] = Form.useForm<BasicFormValues>();

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "teacher") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  const loadDetail = useCallback(async () => {
    setLoading(true);
    try {
      const data = await teacherGetAssignmentDetail(assignmentId);
      if (data.status !== "draft") {
        message.warning("仅草稿作业可编辑");
        navigate("/teacher/assignments");
        return;
      }
      setDetail(data);
      setQuestions(data.questions);
      form.setFieldsValue({
        title: data.title,
        description: data.description ?? undefined,
        deadline: data.deadline ? dayjs(data.deadline) : null,
      });
    } catch (error) {
      message.error(toErrorMessage(error, "加载作业详情失败"));
    } finally {
      setLoading(false);
    }
  }, [assignmentId, form, navigate]);

  useEffect(() => {
    if (authInitialized && user?.role === "teacher" && assignmentId) {
      void loadDetail();
    }
  }, [authInitialized, user, assignmentId, loadDetail]);

  // ── 题目排序 ──────────────────────────────────────────

  const handleMoveQuestion = (index: number, direction: "up" | "down") => {
    setQuestions((prev) => {
      const copy = [...prev];
      const target = direction === "up" ? index - 1 : index + 1;
      if (target < 0 || target >= copy.length) return prev;
      [copy[index], copy[target]] = [copy[target], copy[index]];
      return copy.map((q, i) => ({ ...q, sortOrder: i + 1 }));
    });
  };

  const handleDeleteQuestion = (index: number) => {
    setQuestions((prev) => prev.filter((_, i) => i !== index));
    if (editingIndex === index) setEditingIndex(null);
  };

  const handleUpdateQuestion = (index: number, updated: Question) => {
    setQuestions((prev) => prev.map((q, i) => (i === index ? updated : q)));
    setEditingIndex(null);
  };

  const handleAddQuestion = () => {
    const newQ: Question = {
      questionType: "single_choice",
      sortOrder: questions.length + 1,
      content: "",
      options: [
        { label: "A", text: "" },
        { label: "B", text: "" },
        { label: "C", text: "" },
        { label: "D", text: "" },
      ],
      correctAnswer: { answer: "A" },
      score: 2,
    };
    setQuestions((prev) => [...prev, newQ]);
    setEditingIndex(questions.length);
  };

  // ── 保存 / 发布 ──────────────────────────────────────

  const handleSave = useCallback(async () => {
    try {
      const values = await form.validateFields();
      setSubmitting(true);
      await teacherUpdateAssignment(assignmentId, {
        title: values.title,
        description: values.description || null,
        deadline: values.deadline?.toISOString() ?? null,
      });
      await teacherSaveQuestions(assignmentId, questions);
      message.success("作业已保存");
      navigate("/teacher/assignments");
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) return;
      message.error(toErrorMessage(error, "保存失败"));
    } finally {
      setSubmitting(false);
    }
  }, [assignmentId, form, questions, navigate]);

  const handlePublish = useCallback(async () => {
    try {
      const values = await form.validateFields();
      if (!values.deadline) {
        message.warning("发布作业需要设置截止日期");
        return;
      }
      if (questions.length === 0) {
        message.warning("至少需要一道题目才能发布");
        return;
      }
      setSubmitting(true);
      await teacherUpdateAssignment(assignmentId, {
        title: values.title,
        description: values.description || null,
        deadline: values.deadline.toISOString(),
      });
      await teacherSaveQuestions(assignmentId, questions);
      await teacherPublishAssignment(assignmentId, values.deadline.toISOString());
      message.success("作业已发布");
      navigate("/teacher/assignments");
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) return;
      message.error(toErrorMessage(error, "发布失败"));
    } finally {
      setSubmitting(false);
    }
  }, [assignmentId, form, questions, navigate]);

  if (!authInitialized || !user || user.role !== "teacher" || loading) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  if (!detail) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4">
        <Typography.Text type="secondary">作业不存在或无权访问</Typography.Text>
        <Button onClick={() => navigate("/teacher/assignments")}>
          返回
        </Button>
      </div>
    );
  }

  const totalScore = questions.reduce((s, q) => s + q.score, 0);

  return (
    <div className="flex h-full min-h-0 flex-col gap-4 overflow-y-auto pb-4">
      <div className="flex items-center justify-between">
        <Button
          type="text"
          icon={<ArrowLeftOutlined />}
          onClick={() => navigate("/teacher/assignments")}
        >
          返回作业列表
        </Button>
      </div>

      {/* 基本信息 */}
      <Card size="small" title="基本信息">
        <Form form={form} layout="vertical" autoComplete="off">
          <Form.Item
            name="title"
            label="作业标题"
            rules={[
              { required: true, message: "请输入作业标题" },
              { max: 200, message: "标题不能超过 200 字" },
            ]}
          >
            <Input placeholder="输入作业标题" />
          </Form.Item>
          <Form.Item name="description" label="作业说明">
            <TextArea rows={2} placeholder="输入作业说明（选填）" />
          </Form.Item>
          <Form.Item name="deadline" label="截止日期">
            <DatePicker
              showTime
              format="YYYY-MM-DD HH:mm"
              placeholder="选择截止日期"
              className="w-full"
              disabledDate={(current) => current && current < dayjs().startOf("day")}
            />
          </Form.Item>
        </Form>
      </Card>

      {/* 题目管理 */}
      <div className="flex items-center justify-between">
        <Typography.Title level={5} className="!mb-0">
          题目列表（{questions.length} 题，总分 {totalScore}）
        </Typography.Title>
        <Button size="small" icon={<PlusOutlined />} onClick={handleAddQuestion}>
          添加题目
        </Button>
      </div>

      {questions.map((q, idx) =>
        editingIndex === idx ? (
          <QuestionEditor
            key={idx}
            question={q}
            onSave={(updated) => handleUpdateQuestion(idx, updated)}
            onCancel={() => setEditingIndex(null)}
          />
        ) : (
          <Card key={idx} size="small">
            <div className="flex items-start justify-between gap-2">
              <div className="flex-1 min-w-0">
                <div className="mb-1 flex items-center gap-2">
                  <Tag>{TYPE_LABELS[q.questionType]}</Tag>
                  <span className="text-xs text-gray-400">#{idx + 1}</span>
                  <span className="text-xs text-gray-400">{q.score} 分</span>
                </div>
                <Typography.Paragraph
                  className="!mb-1 whitespace-pre-wrap"
                  ellipsis={{ rows: 3, expandable: true }}
                >
                  {q.content || "(空题目)"}
                </Typography.Paragraph>
                {q.options && q.options.length > 0 && (
                  <div className="space-y-0.5 text-sm text-gray-500">
                    {q.options.map((opt) => (
                      <div key={opt.label}>{opt.label}. {opt.text}</div>
                    ))}
                  </div>
                )}
                <div className="mt-1 text-xs text-green-600">
                  答案: {formatAnswer(q)}
                </div>
              </div>
              <Space direction="vertical" size={2}>
                <Button type="text" size="small" disabled={idx === 0} onClick={() => handleMoveQuestion(idx, "up")}>↑</Button>
                <Button type="text" size="small" disabled={idx === questions.length - 1} onClick={() => handleMoveQuestion(idx, "down")}>↓</Button>
                <Button type="text" size="small" onClick={() => setEditingIndex(idx)}>编辑</Button>
                <Button type="text" size="small" danger icon={<DeleteOutlined />} onClick={() => handleDeleteQuestion(idx)} />
              </Space>
            </div>
          </Card>
        ),
      )}

      {questions.length === 0 && (
        <Card size="small">
          <Typography.Text type="secondary">暂无题目，点击「添加题目」开始</Typography.Text>
        </Card>
      )}

      {/* 底部操作 */}
      <div className="flex items-center justify-end gap-2 border-t pt-3">
        <Button onClick={handleSave} loading={submitting}>
          保存草稿
        </Button>
        <Button type="primary" onClick={handlePublish} loading={submitting}>
          发布作业
        </Button>
      </div>
    </div>
  );
}
