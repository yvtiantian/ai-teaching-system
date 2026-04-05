import {
  DeleteOutlined,
  ReloadOutlined,
  SearchOutlined,
} from "@ant-design/icons";
import {
  Button,
  DatePicker,
  Form,
  Input,
  Modal,
  Select,
  Space,
  Spin,
  Tag,
  message,
} from "antd";
import type { TableColumnsType } from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useNavigate } from "react-router";
import { useCallback, useEffect, useMemo, useState } from "react";
import CommonTable from "@/components/CommonTable/CommonTable";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  adminDeleteAssignment,
  adminListAssignments,
  adminUpdateAssignment,
} from "@/services/adminAssignments";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, formatDateTime } from "@/lib/utils";
import type { AdminAssignment, AssignmentStatus } from "@/types/assignment";

dayjs.locale("zh-cn");

const STATUS_OPTIONS: Array<{ label: string; value: AssignmentStatus }> = [
  { label: "草稿", value: "draft" },
  { label: "已发布", value: "published" },
  { label: "已关闭", value: "closed" },
];

const STATUS_TAG: Record<AssignmentStatus, { color: string; label: string }> = {
  draft: { color: "default", label: "草稿" },
  published: { color: "green", label: "已发布" },
  closed: { color: "red", label: "已关闭" },
};

interface FilterFormValues {
  keyword?: string;
  status?: AssignmentStatus;
}

interface QueryState {
  filters: { keyword?: string; status?: string };
  page: number;
  pageSize: number;
}

const DEFAULT_QUERY_STATE: QueryState = {
  filters: {},
  page: 1,
  pageSize: 20,
};

export default function AdminAssignmentsPage() {
  const navigate = useNavigate();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [filterForm] = Form.useForm<FilterFormValues>();
  const [deadlineForm] = Form.useForm<{ deadline: dayjs.Dayjs }>();

  const [assignments, setAssignments] = useState<AdminAssignment[]>([]);
  const [queryState, setQueryState] = useState<QueryState>(DEFAULT_QUERY_STATE);
  const [tableLoading, setTableLoading] = useState(false);
  const [total, setTotal] = useState(0);

  // 修改截止日期弹窗
  const [deadlineTarget, setDeadlineTarget] = useState<AdminAssignment | null>(null);
  const [submittingDeadline, setSubmittingDeadline] = useState(false);

  const canAccess = authInitialized && user?.role === "admin";

  const loadAssignments = useCallback(async (nextQuery: QueryState) => {
    setTableLoading(true);
    try {
      const result = await adminListAssignments({
        ...nextQuery.filters,
        page: nextQuery.page,
        pageSize: nextQuery.pageSize,
      });

      if (result.items.length === 0 && result.total > 0 && nextQuery.page > 1) {
        setQueryState((prev) => ({ ...prev, page: Math.max(prev.page - 1, 1) }));
        return;
      }

      setAssignments(result.items);
      setTotal(result.total);
    } catch (error) {
      message.error(toErrorMessage(error, "加载作业列表失败"));
      setAssignments([]);
      setTotal(0);
    } finally {
      setTableLoading(false);
    }
  }, []);

  const refreshCurrentData = useCallback(async () => {
    await loadAssignments(queryState);
  }, [loadAssignments, queryState]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "admin") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (!canAccess) return;
    void loadAssignments(queryState);
  }, [canAccess, loadAssignments, queryState]);

  const handleSearch = (values: FilterFormValues) => {
    setQueryState((prev) => ({
      ...prev,
      page: 1,
      filters: {
        keyword: values.keyword?.trim() || undefined,
        status: values.status || undefined,
      },
    }));
  };

  const handleReset = () => {
    filterForm.resetFields();
    setQueryState(DEFAULT_QUERY_STATE);
  };

  const handleClose = useCallback(
    async (record: AdminAssignment) => {
      try {
        await adminUpdateAssignment(record.id, { status: "closed" });
        message.success("作业已关闭");
        await refreshCurrentData();
      } catch (error) {
        message.error(toErrorMessage(error, "关闭作业失败"));
      }
    },
    [refreshCurrentData],
  );

  const handleReopenClick = useCallback(
    (record: AdminAssignment) => {
      setDeadlineTarget(record);
      deadlineForm.resetFields();
    },
    [deadlineForm],
  );

  const handleEditDeadline = useCallback(
    (record: AdminAssignment) => {
      setDeadlineTarget(record);
      deadlineForm.setFieldsValue({
        deadline: record.deadline ? dayjs(record.deadline) : undefined,
      });
    },
    [deadlineForm],
  );

  const handleDeadlineConfirm = async () => {
    if (!deadlineTarget) return;
    try {
      const values = await deadlineForm.validateFields();
      setSubmittingDeadline(true);
      if (deadlineTarget.status === "closed") {
        // reopen
        await adminUpdateAssignment(deadlineTarget.id, {
          status: "published",
          deadline: values.deadline.toISOString(),
        });
        message.success("作业已重新开放");
      } else {
        // just update deadline
        await adminUpdateAssignment(deadlineTarget.id, {
          deadline: values.deadline.toISOString(),
        });
        message.success("截止日期已更新");
      }
      setDeadlineTarget(null);
      await refreshCurrentData();
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) return;
      message.error(toErrorMessage(error, "操作失败"));
    } finally {
      setSubmittingDeadline(false);
    }
  };

  const handleDelete = useCallback(
    (record: AdminAssignment) => {
      Modal.confirm({
        title: "删除作业",
        content: `确定删除「${record.title}」？此操作不可恢复，该作业下所有题目、学生提交记录及答案将被永久删除。`,
        okText: "删除",
        okType: "danger",
        cancelText: "取消",
        onOk: async () => {
          try {
            await adminDeleteAssignment(record.id);
            message.success("作业已删除");
            await refreshCurrentData();
          } catch (error) {
            message.error(toErrorMessage(error, "删除作业失败"));
          }
        },
      });
    },
    [refreshCurrentData],
  );

  const columns: TableColumnsType<AdminAssignment> = useMemo(
    () => [
      {
        title: "作业标题",
        dataIndex: "title",
        ellipsis: true,
      },
      {
        title: "所属课程",
        dataIndex: "courseName",
        width: 160,
        ellipsis: true,
      },
      {
        title: "授课教师",
        dataIndex: "teacherName",
        width: 120,
      },
      {
        title: "题目数",
        dataIndex: "questionCount",
        width: 80,
        align: "center",
      },
      {
        title: "总分",
        dataIndex: "totalScore",
        width: 80,
        align: "center",
      },
      {
        title: "状态",
        dataIndex: "status",
        width: 90,
        render: (status: AssignmentStatus) => {
          const tag = STATUS_TAG[status] || { color: "default", label: status };
          return <Tag color={tag.color}>{tag.label}</Tag>;
        },
      },
      {
        title: "截止时间",
        dataIndex: "deadline",
        width: 160,
        render: (v: string | null) => formatDateTime(v),
      },
      {
        title: "创建时间",
        dataIndex: "createdAt",
        width: 160,
        render: (v: string) => formatDateTime(v),
      },
      {
        title: "操作",
        key: "actions",
        width: 280,
        fixed: "right",
        render: (_: unknown, record) => (
          <Space size="small" wrap>
            <Button
              type="link"
              size="small"
              onClick={() => navigate(`/admin/assignments/${record.id}`)}
            >
              详情
            </Button>
            {record.status === "published" && (
              <>
                <Button type="link" size="small" onClick={() => handleEditDeadline(record)}>
                  改期
                </Button>
                <Button type="link" size="small" onClick={() => void handleClose(record)}>
                  关闭
                </Button>
              </>
            )}
            {record.status === "closed" && (
              <Button type="link" size="small" onClick={() => handleReopenClick(record)}>
                重新开放
              </Button>
            )}
            <Button
              type="link"
              size="small"
              danger
              icon={<DeleteOutlined />}
              onClick={() => handleDelete(record)}
            >
              删除
            </Button>
          </Space>
        ),
      },
    ],
    [handleClose, handleDelete, handleEditDeadline, handleReopenClick, navigate],
  );

  if (!authInitialized || !user || user.role !== "admin") {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col">
      <Form form={filterForm} layout="inline" onFinish={handleSearch} className="w-full gap-y-2">
        <Form.Item name="keyword" className="min-w-[220px] flex-1">
          <Input
            allowClear
            prefix={<SearchOutlined />}
            placeholder="搜索作业标题"
          />
        </Form.Item>
        <Form.Item name="status" className="min-w-[132px]">
          <Select allowClear placeholder="状态" options={STATUS_OPTIONS} />
        </Form.Item>
        <Form.Item>
          <Space>
            <Button type="primary" htmlType="submit">查询</Button>
            <Button onClick={handleReset}>重置</Button>
            <Button icon={<ReloadOutlined />} onClick={() => void refreshCurrentData()}>
              刷新
            </Button>
          </Space>
        </Form.Item>
      </Form>

      <div className="flex-1 min-h-0 mt-2">
        <CommonTable<AdminAssignment>
          columns={columns}
          dataSource={assignments}
          rowKey="id"
          loading={tableLoading}
          scroll={{ x: 1400 }}
          pagination={{
            current: queryState.page,
            pageSize: queryState.pageSize,
            total,
            onChange: (page, pageSize) => {
              setQueryState((prev) => ({
                ...prev,
                page: pageSize !== prev.pageSize ? 1 : page,
                pageSize,
              }));
            },
          }}
          paginationMode="server"
          empty={{ title: "暂无作业数据" }}
        />
      </div>

      {/* 修改截止日期 / 重新开放弹窗 */}
      <Modal
        title={deadlineTarget?.status === "closed" ? "重新开放作业" : "修改截止日期"}
        open={Boolean(deadlineTarget)}
        onCancel={() => setDeadlineTarget(null)}
        onOk={() => void handleDeadlineConfirm()}
        confirmLoading={submittingDeadline}
        okText="确定"
        cancelText="取消"
        destroyOnHidden
      >
        <Form
          form={deadlineForm}
          layout="vertical"
          requiredMark={false}
        >
          <Form.Item
            name="deadline"
            label="新截止日期"
            rules={[{ required: true, message: "请选择截止日期" }]}
          >
            <DatePicker
              showTime
              format="YYYY-MM-DD HH:mm"
              disabledDate={(current) => current && current < dayjs().startOf("day")}
              className="w-full"
            />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
}
