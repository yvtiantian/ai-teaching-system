import {
  ArrowLeftOutlined,
  ReloadOutlined,
} from "@ant-design/icons";
import {
  Button,
  Card,
  Descriptions,
  Select,
  Space,
  Spin,
  Statistic,
  Tabs,
  Tag,
  Typography,
  message,
} from "antd";
import type { TableColumnsType } from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useParams, useNavigate } from "react-router";
import { useCallback, useEffect, useMemo, useState } from "react";
import CommonTable from "@/components/CommonTable/CommonTable";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  adminGetAssignmentDetail,
  adminListSubmissions,
} from "@/services/adminAssignments";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, formatDateTime, QUESTION_TYPE_LABEL } from "@/lib/utils";
import type {
  AdminAssignmentDetail,
  AdminSubmission,
  AssignmentStatus,
  Question,
  QuestionType,
  SubmissionStatus,
} from "@/types/assignment";

dayjs.locale("zh-cn");

const STATUS_TAG: Record<AssignmentStatus, { color: string; label: string }> = {
  draft: { color: "default", label: "草稿" },
  published: { color: "green", label: "已发布" },
  closed: { color: "red", label: "已关闭" },
};

const SUBMISSION_STATUS_TAG: Record<SubmissionStatus, { color: string; label: string }> = {
  not_started: { color: "default", label: "未开始" },
  in_progress: { color: "processing", label: "作答中" },
  submitted: { color: "blue", label: "已提交" },
  ai_grading: { color: "processing", label: "AI批改中" },
  ai_graded: { color: "orange", label: "待复核" },
  graded: { color: "green", label: "已批改" },
};

const SUBMISSION_STATUS_OPTIONS: Array<{ label: string; value: SubmissionStatus }> = [
  { label: "已提交", value: "submitted" },
  { label: "AI批改中", value: "ai_grading" },
  { label: "待复核", value: "ai_graded" },
  { label: "已批改", value: "graded" },
];

export default function AdminAssignmentDetailPage() {
  const navigate = useNavigate();
  const params = useParams();
  const assignmentId = params.id as string;
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [detail, setDetail] = useState<AdminAssignmentDetail | null>(null);
  const [loading, setLoading] = useState(true);

  // submissions tab state
  const [submissions, setSubmissions] = useState<AdminSubmission[]>([]);
  const [submissionsTotal, setSubmissionsTotal] = useState(0);
  const [submissionsPage, setSubmissionsPage] = useState(1);
  const [submissionsPageSize, setSubmissionsPageSize] = useState(20);
  const [submissionStatusFilter, setSubmissionStatusFilter] = useState<string | undefined>();
  const [submissionsLoading, setSubmissionsLoading] = useState(false);

  const canAccess = authInitialized && user?.role === "admin";

  const loadDetail = useCallback(async () => {
    setLoading(true);
    try {
      const data = await adminGetAssignmentDetail(assignmentId);
      setDetail(data);
    } catch (error) {
      message.error(toErrorMessage(error, "加载作业详情失败"));
    } finally {
      setLoading(false);
    }
  }, [assignmentId]);

  const loadSubmissions = useCallback(async () => {
    setSubmissionsLoading(true);
    try {
      const res = await adminListSubmissions(assignmentId, {
        status: submissionStatusFilter,
        page: submissionsPage,
        pageSize: submissionsPageSize,
      });
      setSubmissions(res.items);
      setSubmissionsTotal(res.total);
    } catch (error) {
      message.error(toErrorMessage(error, "加载提交列表失败"));
      setSubmissions([]);
      setSubmissionsTotal(0);
    } finally {
      setSubmissionsLoading(false);
    }
  }, [assignmentId, submissionStatusFilter, submissionsPage, submissionsPageSize]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "admin") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (canAccess && assignmentId) void loadDetail();
  }, [canAccess, assignmentId, loadDetail]);

  useEffect(() => {
    if (canAccess && assignmentId) void loadSubmissions();
  }, [canAccess, assignmentId, loadSubmissions]);

  // ── Question columns ──────────────────────────────────

  const questionColumns: TableColumnsType<Question> = useMemo(
    () => [
      {
        title: "序号",
        dataIndex: "sortOrder",
        width: 70,
        align: "center",
      },
      {
        title: "题型",
        dataIndex: "questionType",
        width: 100,
        render: (t: QuestionType) => QUESTION_TYPE_LABEL[t] || t,
      },
      {
        title: "题目内容",
        dataIndex: "content",
        ellipsis: true,
      },
      {
        title: "分值",
        dataIndex: "score",
        width: 80,
        align: "center",
      },
    ],
    [],
  );

  // ── Submission columns ────────────────────────────────

  const assignmentTotalScore = detail?.assignment.totalScore ?? 0;

  const submissionColumns: TableColumnsType<AdminSubmission> = useMemo(
    () => [
      {
        title: "学生姓名",
        dataIndex: "studentName",
        ellipsis: true,
      },
      {
        title: "提交状态",
        dataIndex: "status",
        width: 120,
        render: (s: SubmissionStatus) => {
          const tag = SUBMISSION_STATUS_TAG[s] || { color: "default", label: s };
          return <Tag color={tag.color}>{tag.label}</Tag>;
        },
      },
      {
        title: "得分",
        dataIndex: "totalScore",
        width: 120,
        align: "center",
        render: (v: number | null) =>
          v != null ? (
            <span>
              <span className="font-medium">{v}</span>
              <span className="text-gray-400"> / {assignmentTotalScore}</span>
            </span>
          ) : (
            "-"
          ),
      },
      {
        title: "提交时间",
        dataIndex: "submittedAt",
        width: 180,
        render: (v: string | null) => formatDateTime(v),
      },
      {
        title: "操作",
        key: "actions",
        width: 100,
        render: (_: unknown, record) => (
          <Button
            type="link"
            size="small"
            onClick={() =>
              navigate(`/admin/assignments/${assignmentId}/submissions/${record.id}`)
            }
          >
            查看
          </Button>
        ),
      },
    ],
    [assignmentId, assignmentTotalScore, navigate],
  );

  if (!authInitialized || !user || user.role !== "admin" || loading) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  if (!detail) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4">
        <Typography.Text type="secondary">作业不存在</Typography.Text>
        <Button onClick={() => navigate("/admin/assignments")}>返回作业列表</Button>
      </div>
    );
  }

  const { assignment: a, stats, questions } = detail;
  const statusTag = STATUS_TAG[a.status] || { color: "default", label: a.status };

  return (
    <div className="flex h-full min-h-0 flex-col gap-4">
      {/* Header */}
      <div className="flex items-center justify-between">
        <Button
          type="text"
          icon={<ArrowLeftOutlined />}
          onClick={() => navigate("/admin/assignments")}
        >
          返回作业列表
        </Button>
        <Button icon={<ReloadOutlined />} onClick={() => void loadDetail()}>
          刷新
        </Button>
      </div>

      {/* Tabs */}
      <Tabs
        defaultActiveKey="overview"
        className="flex-1 min-h-0"
        items={[
          {
            key: "overview",
            label: "概览",
            children: (
              <div className="flex flex-col gap-4">
                <Descriptions bordered size="small" column={{ xs: 1, sm: 2 }}>
                  <Descriptions.Item label="作业标题">{a.title}</Descriptions.Item>
                  <Descriptions.Item label="状态">
                    <Tag color={statusTag.color}>{statusTag.label}</Tag>
                  </Descriptions.Item>
                  <Descriptions.Item label="所属课程">{a.courseName}</Descriptions.Item>
                  <Descriptions.Item label="授课教师">{a.teacherName}</Descriptions.Item>
                  <Descriptions.Item label="总分">{a.totalScore}</Descriptions.Item>
                  <Descriptions.Item label="截止时间">
                    {formatDateTime(a.deadline)}
                  </Descriptions.Item>
                  <Descriptions.Item label="发布时间">
                    {formatDateTime(a.publishedAt)}
                  </Descriptions.Item>
                  <Descriptions.Item label="创建时间">
                    {formatDateTime(a.createdAt)}
                  </Descriptions.Item>
                  {a.description && (
                    <Descriptions.Item label="描述" span={2}>
                      {a.description}
                    </Descriptions.Item>
                  )}
                </Descriptions>

                <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
                  <Card size="small">
                    <Statistic title="课程学生数" value={stats.studentCount} />
                  </Card>
                  <Card size="small">
                    <Statistic title="已提交" value={stats.submittedCount} />
                  </Card>
                  <Card size="small">
                    <Statistic title="待复核" value={stats.aiGradedCount} />
                  </Card>
                  <Card size="small">
                    <Statistic title="已批改" value={stats.gradedCount} />
                  </Card>
                </div>

                {(stats.avgScore != null || stats.maxScore != null) && (
                  <div className="grid grid-cols-3 gap-4">
                    <Card size="small">
                      <Statistic
                        title="平均分"
                        value={stats.avgScore ?? "-"}
                        precision={1}
                      />
                    </Card>
                    <Card size="small">
                      <Statistic title="最高分" value={stats.maxScore ?? "-"} />
                    </Card>
                    <Card size="small">
                      <Statistic title="最低分" value={stats.minScore ?? "-"} />
                    </Card>
                  </div>
                )}
              </div>
            ),
          },
          {
            key: "questions",
            label: `题目 (${questions.length})`,
            children: (
              <CommonTable<Question>
                columns={questionColumns}
                dataSource={questions}
                rowKey={(q) => q.id || String(q.sortOrder)}
                scroll={{ x: 600 }}
                empty={{ title: "暂无题目" }}
              />
            ),
          },
          {
            key: "submissions",
            label: `提交 (${submissionsTotal})`,
            children: (
              <div className="flex flex-col gap-2">
                <Space>
                  <Select
                    allowClear
                    placeholder="提交状态"
                    options={SUBMISSION_STATUS_OPTIONS}
                    value={submissionStatusFilter}
                    onChange={(val) => {
                      setSubmissionStatusFilter(val);
                      setSubmissionsPage(1);
                    }}
                    className="min-w-[140px]"
                  />
                  <Button
                    icon={<ReloadOutlined />}
                    onClick={() => void loadSubmissions()}
                  >
                    刷新
                  </Button>
                </Space>
                <CommonTable<AdminSubmission>
                  columns={submissionColumns}
                  dataSource={submissions}
                  rowKey="id"
                  loading={submissionsLoading}
                  scroll={{ x: 700 }}
                  pagination={{
                    current: submissionsPage,
                    pageSize: submissionsPageSize,
                    total: submissionsTotal,
                    onChange: (page, pageSize) => {
                      if (pageSize !== submissionsPageSize) {
                        setSubmissionsPage(1);
                        setSubmissionsPageSize(pageSize);
                      } else {
                        setSubmissionsPage(page);
                      }
                    },
                  }}
                  paginationMode="server"
                  empty={{ title: "暂无提交记录" }}
                />
              </div>
            ),
          },
        ]}
      />
    </div>
  );
}
