import {
  ArrowLeftOutlined,
  DeleteOutlined,
  InboxOutlined,
  PlusOutlined,
} from "@ant-design/icons";
import {
  Button,
  Card,
  DatePicker,
  Form,
  Input,
  InputNumber,
  message,
  Modal,
  Select,
  Space,
  Spin,
  Steps,
  Switch,
  Tag,
  Typography,
  Upload,
} from "antd";
import type { UploadFile } from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useNavigate, useSearchParams } from "react-router";
import { Suspense, useCallback, useEffect, useState } from "react";
import { getRoleRedirectPath } from "@/lib/profile";
import { getSupabaseClient } from "@/lib/supabase";
import {
  teacherCreateAssignment,
  teacherPublishAssignment,
  teacherSaveQuestions,
  generateAssignmentQuestions,
} from "@/services/teacherAssignments";
import { teacherListCourses } from "@/services/teacherCourses";
import QuestionEditor, { formatAnswer } from "@/components/assignments/QuestionEditor";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, QUESTION_TYPE_LABELS } from "@/lib/utils";
import type {
  Question,
  QuestionConfig,
  QuestionType,
} from "@/types/assignment";
import type { TeacherCourse } from "@/types/course";

dayjs.locale("zh-cn");

/** 将字面 \n 转为真正的换行符 */
const nl = (s: string) => s.replace(/\\n/g, "\n");

const { TextArea } = Input;
const { Dragger } = Upload;

const ALLOWED_MIME_TYPES = [
  "application/pdf",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "text/plain",
  "text/markdown",
];
const MAX_FILE_SIZE = 20 * 1024 * 1024; // 20MB

const DEFAULT_AI_PROMPT = `请确保题目:
- 难度适中，覆盖核心知识点
- 选项设计合理，干扰项有迷惑性
- 每道题附带答案解析
- 题目不重复或过于相似`;

const DEFAULT_QUESTION_CONFIG: QuestionConfig = {
  single_choice: { count: 5, scorePerQuestion: 2 },
  multiple_choice: { count: 0, scorePerQuestion: 4 },
  fill_blank: { count: 0, scorePerQuestion: 3 },
  true_false: { count: 0, scorePerQuestion: 2 },
  short_answer: { count: 0, scorePerQuestion: 10 },
};

interface BasicInfo {
  title: string;
  description: string;
  deadline: dayjs.Dayjs | null;
}

function CreateAssignmentInner() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const initialCourseId = searchParams.get("courseId") || null;
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [courses, setCourses] = useState<TeacherCourse[]>([]);
  const [courseId, setCourseId] = useState<string | null>(initialCourseId);
  const [currentStep, setCurrentStep] = useState(0);

  // Step 1: 基本信息
  const [basicInfo, setBasicInfo] = useState<BasicInfo>({
    title: "",
    description: "",
    deadline: null,
  });
  const [basicForm] = Form.useForm<BasicInfo>();

  // Step 2: 文件上传
  const [fileList, setFileList] = useState<UploadFile[]>([]);
  const [uploadedPaths, setUploadedPaths] = useState<string[]>([]);

  // Step 3: 题目配置
  const [questionConfig, setQuestionConfig] = useState<QuestionConfig>(DEFAULT_QUESTION_CONFIG);
  const [aiPrompt, setAiPrompt] = useState(DEFAULT_AI_PROMPT);
  const [generating, setGenerating] = useState(false);

  // Step 4: 预览题目
  const [questions, setQuestions] = useState<Question[]>([]);
  const [editingIndex, setEditingIndex] = useState<number | null>(null);

  // 手动添加题目弹窗
  const [addingQuestion, setAddingQuestion] = useState<Question | null>(null);

  // 保存/发布
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "teacher") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  // 加载课程列表
  useEffect(() => {
    if (!authInitialized || !user || user.role !== "teacher") return;
    void teacherListCourses().then((data) => {
      setCourses(data.filter((c) => c.status === "active"));
    });
  }, [authInitialized, user]);

  // ── Step 导航 ──────────────────────────────────────────

  const handleNextStep = async () => {
    if (currentStep === 0) {
      if (!courseId) {
        message.warning("请先选择课程");
        return;
      }
      try {
        const values = await basicForm.validateFields();
        setBasicInfo(values);
        setCurrentStep(1);
      } catch { /* validation error */ }
    } else if (currentStep === 1) {
      setCurrentStep(2);
    } else if (currentStep === 2) {
      await handleGenerate();
    }
  };

  const handlePrevStep = () => {
    setCurrentStep((prev) => Math.max(0, prev - 1));
  };

  // ── 文件上传 ───────────────────────────────────────────

  const handleUpload = async (file: File) => {
    if (!courseId) return false;
    if (!ALLOWED_MIME_TYPES.includes(file.type)) {
      message.error("不支持的文件格式，请上传 PDF、DOCX、PPTX 或 TXT 文件");
      return false;
    }
    if (file.size > MAX_FILE_SIZE) {
      message.error("文件大小不能超过 20MB");
      return false;
    }

    const supabase = getSupabaseClient();
    const uid = crypto.randomUUID();
    const ext = file.name.includes(".") ? file.name.substring(file.name.lastIndexOf(".")) : "";
    const path = `${courseId}/temp/${uid}${ext}`;

    const { error } = await supabase.storage
      .from("assignment-materials")
      .upload(path, file, { contentType: file.type });

    if (error) {
      message.error(`上传失败: ${error.message}`);
      return false;
    }

    setUploadedPaths((prev) => [...prev, `assignment-materials/${path}`]);
    return true;
  };

  // ── AI 生成 ───────────────────────────────────────────

  const totalCount = Object.values(questionConfig).reduce(
    (sum, cfg) => sum + (cfg?.count ?? 0),
    0,
  );
  const totalScore = Object.values(questionConfig).reduce(
    (sum, cfg) => sum + (cfg?.count ?? 0) * (cfg?.scorePerQuestion ?? 0),
    0,
  );

  const handleGenerate = async () => {
    if (!courseId) return;
    if (totalCount === 0) {
      message.warning("请至少配置一种题型且数量大于 0");
      return;
    }

    setGenerating(true);
    try {
      const result = await generateAssignmentQuestions({
        courseId,
        title: basicInfo.title,
        description: basicInfo.description || undefined,
        filePaths: uploadedPaths,
        questionConfig,
        aiPrompt: aiPrompt || undefined,
      });
      setQuestions(result.questions);
      setCurrentStep(3);
      message.success(`已生成 ${result.questions.length} 道题目`);
    } catch (error) {
      message.error(toErrorMessage(error, "AI 生成失败，请重试"));
    } finally {
      setGenerating(false);
    }
  };

  // ── 题目编辑 ───────────────────────────────────────────

  const handleDeleteQuestion = (index: number) => {
    setQuestions((prev) => prev.filter((_, i) => i !== index));
    if (editingIndex === index) setEditingIndex(null);
  };

  const handleMoveQuestion = (index: number, direction: "up" | "down") => {
    setQuestions((prev) => {
      const copy = [...prev];
      const target = direction === "up" ? index - 1 : index + 1;
      if (target < 0 || target >= copy.length) return prev;
      [copy[index], copy[target]] = [copy[target], copy[index]];
      return copy.map((q, i) => ({ ...q, sortOrder: i + 1 }));
    });
  };

  const handleUpdateQuestion = (index: number, updated: Question) => {
    setQuestions((prev) => prev.map((q, i) => (i === index ? updated : q)));
    setEditingIndex(null);
  };

  const handleAddQuestion = () => {
    setAddingQuestion({
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
    });
  };

  const handleAddQuestionConfirm = (q: Question) => {
    setQuestions((prev) => [...prev, { ...q, sortOrder: prev.length + 1 }]);
    setAddingQuestion(null);
  };

  // ── 保存 / 发布 ──────────────────────────────────────

  const handleSaveDraft = useCallback(async () => {
    if (!courseId) return;
    if (!basicInfo.title.trim()) {
      message.warning("请先填写作业标题");
      return;
    }
    setSubmitting(true);
    try {
      const assignment = await teacherCreateAssignment({
        courseId,
        title: basicInfo.title,
        description: basicInfo.description || null,
      });
      if (questions.length > 0) {
        await teacherSaveQuestions(assignment.id, questions);
      }
      message.success("作业草稿已保存");
      navigate("/teacher/assignments");
    } catch (error) {
      message.error(toErrorMessage(error, "保存失败"));
    } finally {
      setSubmitting(false);
    }
  }, [basicInfo, courseId, questions, navigate]);

  const handlePublish = useCallback(async () => {
    if (!courseId) return;
    if (!basicInfo.title.trim()) {
      message.warning("请先填写作业标题");
      return;
    }
    if (questions.length === 0) {
      message.warning("至少需要一道题目才能发布");
      return;
    }
    if (!basicInfo.deadline) {
      message.warning("请先设置截止日期");
      return;
    }

    setSubmitting(true);
    try {
      const assignment = await teacherCreateAssignment({
        courseId,
        title: basicInfo.title,
        description: basicInfo.description || null,
      });
      await teacherSaveQuestions(assignment.id, questions);
      await teacherPublishAssignment(
        assignment.id,
        basicInfo.deadline.toISOString(),
      );
      message.success("作业已发布");
      navigate("/teacher/assignments");
    } catch (error) {
      message.error(toErrorMessage(error, "发布失败"));
    } finally {
      setSubmitting(false);
    }
  }, [basicInfo, courseId, questions, navigate]);

  if (!authInitialized || !user || user.role !== "teacher") {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col gap-4">
      {/* Header */}
      <div className="flex-none flex items-center justify-between">
        <Button
          type="text"
          icon={<ArrowLeftOutlined />}
          onClick={() => navigate("/teacher/assignments")}
        >
          返回作业列表
        </Button>
      </div>

      {/* Steps */}
      <Steps
        current={currentStep}
        size="small"
        items={[
          { title: "基本信息" },
          { title: "参考资料" },
          { title: "题目配置" },
          { title: "预览调整" },
        ]}
      />

      {/* Step Content */}
      <div className="flex-1 min-h-0 overflow-y-auto">
        {currentStep === 0 && (
          <StepBasicInfo
            form={basicForm}
            initialValues={basicInfo}
            courses={courses}
            courseId={courseId}
            onCourseChange={setCourseId}
          />
        )}
        {currentStep === 1 && (
          <StepFileUpload
            fileList={fileList}
            setFileList={setFileList}
            onUpload={handleUpload}
            onRemoveFile={(file) => {
              const idx = fileList.findIndex((f) => f.uid === file.uid);
              setFileList((prev) => prev.filter((f) => f.uid !== file.uid));
              if (idx !== -1) {
                setUploadedPaths((prev) => prev.filter((_, i) => i !== idx));
              }
            }}
          />
        )}
        {currentStep === 2 && (
          <StepQuestionConfig
            config={questionConfig}
            setConfig={setQuestionConfig}
            aiPrompt={aiPrompt}
            setAiPrompt={setAiPrompt}
            totalCount={totalCount}
            totalScore={totalScore}
          />
        )}
        {currentStep === 3 && (
          <StepPreview
            questions={questions}
            onEdit={setEditingIndex}
            onDelete={handleDeleteQuestion}
            onMove={handleMoveQuestion}
            onAdd={handleAddQuestion}
          />
        )}
      </div>

      {/* 手动添加题目弹窗 */}
      <Modal
        title="手动添加题目"
        open={!!addingQuestion}
        onCancel={() => setAddingQuestion(null)}
        footer={null}
        width={640}
        destroyOnClose
      >
        {addingQuestion && (
          <QuestionEditor
            question={addingQuestion}
            onSave={handleAddQuestionConfirm}
            onCancel={() => setAddingQuestion(null)}
          />
        )}
      </Modal>

      {/* 编辑题目弹窗 */}
      <Modal
        title="编辑题目"
        open={editingIndex !== null}
        onCancel={() => setEditingIndex(null)}
        footer={null}
        width={640}
        destroyOnClose
      >
        {editingIndex !== null && questions[editingIndex] && (
          <QuestionEditor
            question={questions[editingIndex]}
            onSave={(updated) => handleUpdateQuestion(editingIndex, updated)}
            onCancel={() => setEditingIndex(null)}
          />
        )}
      </Modal>

      {/* Footer Actions */}
      <div className="flex-none flex items-center justify-between border-t pt-3 pb-2">
        <div>
          {currentStep > 0 && (
            <Button onClick={handlePrevStep} disabled={generating || submitting}>
              上一步
            </Button>
          )}
        </div>
        <Space>
          {currentStep < 3 && (
            <Button
              type="primary"
              onClick={handleNextStep}
              loading={generating}
              disabled={submitting}
            >
              {currentStep === 2
                ? generating
                  ? "正在生成..."
                  : "生成题目"
                : "下一步"}
            </Button>
          )}
          {currentStep === 3 && (
            <>
              <Button onClick={handleSaveDraft} loading={submitting}>
                保存草稿
              </Button>
              <Button type="primary" onClick={handlePublish} loading={submitting}>
                发布作业
              </Button>
            </>
          )}
        </Space>
      </div>
    </div>
  );
}

export default function CreateAssignmentPage() {
  return (
    <Suspense
      fallback={
        <div className="flex h-full items-center justify-center">
          <Spin size="large" />
        </div>
      }
    >
      <CreateAssignmentInner />
    </Suspense>
  );
}

// ── Step 1: 基本信息（含课程选择） ─────────────────────

function StepBasicInfo({
  form,
  initialValues,
  courses,
  courseId,
  onCourseChange,
}: {
  form: ReturnType<typeof Form.useForm<BasicInfo>>[0];
  initialValues: BasicInfo;
  courses: TeacherCourse[];
  courseId: string | null;
  onCourseChange: (id: string) => void;
}) {
  return (
    <Card>
      <div className="mb-4">
        <Typography.Text strong className="!mb-1 block text-sm">
          选择课程
        </Typography.Text>
        <Select
          placeholder="选择要布置作业的课程"
          value={courseId}
          onChange={onCourseChange}
          className="w-full"
          options={courses.map((c) => ({ label: c.name, value: c.id }))}
        />
      </div>
      <Form
        form={form}
        layout="vertical"
        initialValues={initialValues}
        autoComplete="off"
      >
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
          <TextArea rows={3} placeholder="输入作业说明（选填）" />
        </Form.Item>
        <Form.Item
          name="deadline"
          label="截止日期"
          rules={[{ required: true, message: "请选择截止日期" }]}
        >
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
  );
}

// ── Step 2: 参考资料 ────────────────────────────────────

function StepFileUpload({
  fileList,
  setFileList,
  onUpload,
  onRemoveFile,
}: {
  fileList: UploadFile[];
  setFileList: React.Dispatch<React.SetStateAction<UploadFile[]>>;
  onUpload: (file: File) => Promise<boolean>;
  onRemoveFile: (file: UploadFile) => void;
}) {
  return (
    <Card>
      <Typography.Paragraph type="secondary" className="!mb-4">
        上传参考资料，AI 将基于资料内容生成题目。支持 PDF、DOCX、PPTX、TXT 格式，单文件最大
        20MB。
      </Typography.Paragraph>
      <Dragger
        multiple
        fileList={fileList}
        beforeUpload={async (file) => {
          const ok = await onUpload(file as unknown as File);
          if (ok) {
            setFileList((prev) => [
              ...prev,
              { uid: file.uid, name: file.name, status: "done" },
            ]);
          }
          return false;
        }}
        onRemove={(file) => {
          onRemoveFile(file);
        }}
      >
        <p className="ant-upload-drag-icon">
          <InboxOutlined />
        </p>
        <p className="ant-upload-text">点击或拖拽文件到此区域上传</p>
        <p className="ant-upload-hint">
          支持 PDF、DOCX、PPTX、TXT（不上传也可以生成题目）
        </p>
      </Dragger>
    </Card>
  );
}

// ── Step 3: 题目配置 ────────────────────────────────────

function StepQuestionConfig({
  config,
  setConfig,
  aiPrompt,
  setAiPrompt,
  totalCount,
  totalScore,
}: {
  config: QuestionConfig;
  setConfig: React.Dispatch<React.SetStateAction<QuestionConfig>>;
  aiPrompt: string;
  setAiPrompt: (v: string) => void;
  totalCount: number;
  totalScore: number;
}) {
  const types: QuestionType[] = [
    "single_choice",
    "multiple_choice",
    "fill_blank",
    "true_false",
    "short_answer",
  ];

  const updateConfig = (type: QuestionType, field: "count" | "scorePerQuestion", value: number) => {
    setConfig((prev) => ({
      ...prev,
      [type]: { ...prev[type], [field]: value },
    }));
  };

  const toggleType = (type: QuestionType, enabled: boolean) => {
    setConfig((prev) => {
      const current = prev[type] ?? DEFAULT_QUESTION_CONFIG[type]!;
      if (!enabled) {
        return {
          ...prev,
          [type]: { ...current, count: 0 },
        };
      }

      return {
        ...prev,
        [type]: {
          ...current,
          count: current.count > 0 ? current.count : 1,
          scorePerQuestion:
            current.scorePerQuestion > 0
              ? current.scorePerQuestion
              : DEFAULT_QUESTION_CONFIG[type]!.scorePerQuestion,
        },
      };
    });
  };

  return (
    <Card>
      <div className="space-y-3">
        <Typography.Text type="secondary" className="block text-sm">
          仅启用的题型会参与本次生成。若只需某一种题型，请关闭其它题型。
        </Typography.Text>
        {types.map((type) => {
          const cfg = config[type] ?? { count: 0, scorePerQuestion: 0 };
          const enabled = cfg.count > 0;
          return (
            <div key={type} className="flex items-center gap-4 rounded-lg border border-gray-100 px-3 py-2">
              <div className="flex min-w-0 flex-1 items-center gap-3">
                <Switch checked={enabled} onChange={(checked) => toggleType(type, checked)} />
                <span className="w-16 shrink-0 text-sm">{QUESTION_TYPE_LABELS[type]}</span>
                {!enabled && <Tag color="default">未启用</Tag>}
              </div>
              <InputNumber
                min={0}
                max={50}
                value={cfg.count}
                onChange={(v) => updateConfig(type, "count", v ?? 0)}
                addonAfter="题"
                className="w-28"
                size="small"
                disabled={!enabled}
              />
              <InputNumber
                min={0}
                max={100}
                value={cfg.scorePerQuestion}
                onChange={(v) => updateConfig(type, "scorePerQuestion", v ?? 0)}
                addonAfter="分/题"
                className="w-32"
                size="small"
                disabled={!enabled}
              />
            </div>
          );
        })}
        <div className="flex gap-6 border-t pt-3 text-sm">
          <span>
            总题数: <strong>{totalCount}</strong>
          </span>
          <span>
            总分: <strong>{totalScore}</strong>
          </span>
        </div>
      </div>

      <div className="mt-4">
        <Typography.Text className="!mb-1 block text-sm" strong>
          AI 提示词补充
        </Typography.Text>
        <TextArea
          rows={4}
          value={aiPrompt}
          onChange={(e) => setAiPrompt(e.target.value)}
          placeholder="可为 AI 出题补充额外要求..."
        />
      </div>
    </Card>
  );
}

// ── Step 4: 预览与调整 ─────────────────────────────────

function StepPreview({
  questions,
  onEdit,
  onDelete,
  onMove,
  onAdd,
}: {
  questions: Question[];
  onEdit: (i: number) => void;
  onDelete: (i: number) => void;
  onMove: (i: number, dir: "up" | "down") => void;
  onAdd: () => void;
}) {
  const totalScore = questions.reduce((s, q) => s + q.score, 0);

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <span className="text-sm">
          共 <strong>{questions.length}</strong> 题，总分{" "}
          <strong>{totalScore}</strong>
        </span>
        <Button size="small" icon={<PlusOutlined />} onClick={onAdd}>
          手动添加
        </Button>
      </div>

      {questions.map((q, idx) => (
          <Card key={idx} size="small" className="!mb-0">
            <div className="flex items-start justify-between gap-2">
              <div className="flex-1 min-w-0">
                <div className="mb-1 flex items-center gap-2">
                  <Tag>{QUESTION_TYPE_LABELS[q.questionType]}</Tag>
                  <span className="text-xs text-gray-400">#{idx + 1}</span>
                  <span className="text-xs text-gray-400">{q.score} 分</span>
                </div>
                <Typography.Paragraph
                  className="!mb-1 whitespace-pre-wrap"
                  ellipsis={{ rows: 3, expandable: true }}
                >
                  {nl(q.content) || "(空题目)"}
                </Typography.Paragraph>
                {q.options && q.options.length > 0 && (
                  <div className="space-y-0.5 text-sm text-gray-500">
                    {q.options.map((opt) => (
                      <div key={opt.label}>
                        {opt.label}. {nl(opt.text)}
                      </div>
                    ))}
                  </div>
                )}
                <div className="mt-1 text-xs text-green-600 whitespace-pre-wrap">
                  答案: {nl(formatAnswer(q))}
                </div>
                {q.explanation && (
                  <div className="mt-0.5 text-xs text-gray-400 whitespace-pre-wrap">
                    解析: {nl(q.explanation)}
                  </div>
                )}
              </div>
              <Space direction="vertical" size={2}>
                <Button
                  type="text"
                  size="small"
                  disabled={idx === 0}
                  onClick={() => onMove(idx, "up")}
                >
                  ↑
                </Button>
                <Button
                  type="text"
                  size="small"
                  disabled={idx === questions.length - 1}
                  onClick={() => onMove(idx, "down")}
                >
                  ↓
                </Button>
                <Button type="text" size="small" onClick={() => onEdit(idx)}>
                  编辑
                </Button>
                <Button
                  type="text"
                  size="small"
                  danger
                  icon={<DeleteOutlined />}
                  onClick={() => onDelete(idx)}
                />
              </Space>
            </div>
          </Card>
      ))}
    </div>
  );
}
