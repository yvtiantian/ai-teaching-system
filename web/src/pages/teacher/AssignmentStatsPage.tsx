import { ArrowLeftOutlined, ReloadOutlined } from "@ant-design/icons";
import {
  Button,
  Card,
  Progress,
  Space,
  Spin,
  Statistic,
  Tag,
  Typography,
  message,
} from "antd";
import type { TableColumnsType } from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useParams, useNavigate } from "react-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import CommonTable from "@/components/CommonTable/CommonTable";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  teacherGetAssignmentStats,
  teacherListSubmissions,
} from "@/services/teacherAssignments";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, formatDateTime } from "@/lib/utils";
import type { AssignmentStats, SubmissionSummary } from "@/types/assignment";

dayjs.locale("zh-cn");

const STATUS_TAG: Record<string, { label: string; color: string }> = {
  not_started: { label: "未作答", color: "default" },
  in_progress: { label: "作答中", color: "processing" },
  submitted: { label: "已提交", color: "green" },
  ai_grading: { label: "AI批改中", color: "orange" },
  ai_graded: { label: "AI已批", color: "cyan" },
  graded: { label: "已复核", color: "blue" },
};

export default function AssignmentStatsPage() {
  const navigate = useNavigate();
  const params = useParams();
  const assignmentId = params.assignmentId as string;
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [stats, setStats] = useState<AssignmentStats | null>(null);
  const [submissions, setSubmissions] = useState<SubmissionSummary[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState<string | undefined>(undefined);
  const reqIdRef = useRef(0);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "teacher") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  const loadData = useCallback(async () => {
    const id = ++reqIdRef.current;
    setLoading(true);
    try {
      const [statsData, submissionData] = await Promise.all([
        teacherGetAssignmentStats(assignmentId),
        teacherListSubmissions(assignmentId, {
          status: statusFilter,
          page,
          pageSize: 20,
        }),
      ]);
      if (id !== reqIdRef.current) return;
      setStats(statsData);
      setSubmissions(submissionData.items);
      setTotal(submissionData.total);
    } catch (error) {
      if (id !== reqIdRef.current) return;
      message.error(toErrorMessage(error, "加载数据失败"));
    } finally {
      if (id === reqIdRef.current) setLoading(false);
    }
  }, [assignmentId, page, statusFilter]);

  useEffect(() => {
    if (authInitialized && user?.role === "teacher" && assignmentId) {
      void loadData();
    }
  }, [authInitialized, user, assignmentId, loadData]);

  const columns: TableColumnsType<SubmissionSummary> = useMemo(
    () => [
      {
        title: "学生姓名",
        dataIndex: "studentName",
        ellipsis: true,
        render: (name: string | null, record) => name || record.studentEmail,
      },
      {
        title: "邮箱",
        dataIndex: "studentEmail",
        width: 200,
        ellipsis: true,
      },
      {
        title: "状态",
        dataIndex: "status",
        width: 100,
        render: (status: string) => {
          const info = STATUS_TAG[status] ?? { label: status, color: "default" };
          return <Tag color={info.color}>{info.label}</Tag>;
        },
      },
      {
        title: "提交时间",
        dataIndex: "submittedAt",
        width: 160,
        render: (value: string | null) => formatDateTime(value),
      },
      {
        title: "得分",
        dataIndex: "totalScore",
        width: 80,
        align: "center",
        render: (v: number | null) => (v != null ? v : "-"),
      },
      {
        title: "操作",
        key: "action",
        width: 100,
        align: "center",
        render: (_: unknown, record: SubmissionSummary) => {
          if (record.status === "ai_grading") {
            return <Tag color="orange">AI批改中</Tag>;
          }
          const canGrade = ["submitted", "ai_graded", "graded"].includes(record.status);
          if (!canGrade) return null;
          return (
            <Button
              type="link"
              size="small"
              onClick={() => navigate(`/teacher/assignments/${assignmentId}/grade/${record.submissionId}`)}
            >
              {record.status === "graded" ? "查看" : "复核"}
            </Button>
          );
        },
      },
    ],
    [assignmentId, navigate],
  );

  if (!authInitialized || !user || user.role !== "teacher") {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

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
        <Button icon={<ReloadOutlined />} onClick={() => void loadData()}>
          刷新
        </Button>
      </div>

      {/* 统计卡片 */}
      {stats && (
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-5">
          <Card size="small">
            <Statistic title="课程总人数" value={stats.totalStudents} />
          </Card>
          <Card size="small">
            <Statistic title="已提交" value={stats.submittedCount} />
          </Card>
          <Card size="small">
            <Statistic title="未提交" value={stats.notSubmittedCount} />
          </Card>
          <Card size="small">
            <Statistic title="AI已批/待复核" value={stats.aiGradedCount} valueStyle={{ color: stats.aiGradedCount > 0 ? "#0891b2" : undefined }} />
          </Card>
          <Card size="small">
            <Statistic
              title="提交率"
              value={stats.submissionRate}
              suffix="%"
              valueStyle={{ color: stats.submissionRate >= 80 ? "#3f8600" : undefined }}
            />
          </Card>
        </div>
      )}

      {stats && (
        <div className="max-w-xs">
          <Progress
            percent={stats.submissionRate}
            status={stats.submissionRate >= 100 ? "success" : "active"}
            format={(p) => `${p}%`}
          />
        </div>
      )}

      {/* 筛选 */}
      <div className="flex items-center gap-2">
        <Typography.Text className="text-sm">筛选:</Typography.Text>
        <Space size="small">
          {[
            { value: undefined, label: "全部" },
            { value: "submitted", label: "已提交" },
            { value: "ai_graded", label: "AI已批" },
            { value: "not_started", label: "未提交" },
            { value: "graded", label: "已复核" },
          ].map((item) => (
            <Tag
              key={item.label}
              color={statusFilter === item.value ? "blue" : undefined}
              className="cursor-pointer"
              onClick={() => {
                setStatusFilter(item.value);
                setPage(1);
              }}
            >
              {item.label}
            </Tag>
          ))}
        </Space>
      </div>

      {/* 提交列表 */}
      <div className="flex-1 min-h-0">
        <CommonTable<SubmissionSummary>
          columns={columns}
          dataSource={submissions}
          rowKey="studentId"
          loading={loading}
          scroll={{ x: 700 }}
          pagination={{
            current: page,
            total,
            pageSize: 20,
            onChange: (p) => setPage(p),
          }}
          empty={{ title: "暂无学生数据" }}
        />
      </div>
    </div>
  );
}
