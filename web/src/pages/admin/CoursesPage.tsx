import {
  DeleteOutlined,
  ReloadOutlined,
  SearchOutlined,
} from "@ant-design/icons";
import {
  Button,
  Form,
  Input,
  Modal,
  Select,
  Space,
  Spin,
  Tag,
  Typography,
  message,
} from "antd";
import type { TableColumnsType } from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useNavigate } from "react-router";
import { useCallback, useEffect, useMemo, useState } from "react";
import CommonTable from "@/components/CommonTable/CommonTable";
import { getCourseStatusTagInfo } from "@/lib/courseStatus";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  adminDeleteCourse,
  adminListCourses,
  adminUpdateCourse,
} from "@/services/adminCourses";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, formatDateTime } from "@/lib/utils";
import type {
  AdminCourse,
  AdminCourseListQuery,
  CourseStatus,
} from "@/types/course";

dayjs.locale("zh-cn");

const STATUS_OPTIONS: Array<{ label: string; value: CourseStatus }> = [
  { label: "进行中", value: "active" },
  { label: "已归档", value: "archived" },
];

interface FilterFormValues {
  keyword?: string;
  status?: CourseStatus;
}

interface EditFormValues {
  name: string;
  description?: string;
}

interface QueryState {
  filters: Omit<AdminCourseListQuery, "page" | "pageSize">;
  page: number;
  pageSize: number;
}

const DEFAULT_QUERY_STATE: QueryState = {
  filters: {},
  page: 1,
  pageSize: 20,
};

export default function AdminCoursesPage() {
  const navigate = useNavigate();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [filterForm] = Form.useForm<FilterFormValues>();
  const [editForm] = Form.useForm<EditFormValues>();

  const [courses, setCourses] = useState<AdminCourse[]>([]);
  const [queryState, setQueryState] = useState<QueryState>(DEFAULT_QUERY_STATE);
  const [tableLoading, setTableLoading] = useState(false);
  const [total, setTotal] = useState(0);

  const [editCourse, setEditCourse] = useState<AdminCourse | null>(null);
  const [submittingEdit, setSubmittingEdit] = useState(false);

  const canAccess = authInitialized && user?.role === "admin";

  const loadCourses = useCallback(async (nextQuery: QueryState) => {
    setTableLoading(true);
    try {
      const result = await adminListCourses({
        ...nextQuery.filters,
        page: nextQuery.page,
        pageSize: nextQuery.pageSize,
      });

      if (result.courses.length === 0 && result.total > 0 && nextQuery.page > 1) {
        setQueryState((prev) => ({ ...prev, page: Math.max(prev.page - 1, 1) }));
        return;
      }

      setCourses(result.courses);
      setTotal(result.total);
    } catch (error) {
      message.error(toErrorMessage(error, "加载课程列表失败"));
      setCourses([]);
      setTotal(0);
    } finally {
      setTableLoading(false);
    }
  }, []);

  const refreshCurrentData = useCallback(async () => {
    await loadCourses(queryState);
  }, [loadCourses, queryState]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "admin") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (!canAccess) return;
    void loadCourses(queryState);
  }, [canAccess, loadCourses, queryState]);

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

  const handleEdit = async () => {
    if (!editCourse) return;
    try {
      const values = await editForm.validateFields();
      setSubmittingEdit(true);
      await adminUpdateCourse(editCourse.id, {
        name: values.name,
        description: values.description || null,
      });
      message.success("课程信息已更新");
      setEditCourse(null);
      await refreshCurrentData();
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) return;
      message.error(toErrorMessage(error, "更新课程失败"));
    } finally {
      setSubmittingEdit(false);
    }
  };

  const handleArchive = useCallback(
    async (course: AdminCourse) => {
      try {
        await adminUpdateCourse(course.id, { status: "archived" });
        message.success("课程已归档");
        await refreshCurrentData();
      } catch (error) {
        message.error(toErrorMessage(error, "归档课程失败"));
      }
    },
    [refreshCurrentData],
  );

  const handleRestore = useCallback(
    async (course: AdminCourse) => {
      try {
        await adminUpdateCourse(course.id, { status: "active" });
        message.success("课程已恢复");
        await refreshCurrentData();
      } catch (error) {
        message.error(toErrorMessage(error, "恢复课程失败"));
      }
    },
    [refreshCurrentData],
  );

  const handleDelete = useCallback(
    (course: AdminCourse) => {
      Modal.confirm({
        title: "删除课程",
        content: `确定删除「${course.name}」？此操作不可恢复，课程下的所有选课记录将被同步删除。`,
        okText: "删除",
        okType: "danger",
        cancelText: "取消",
        onOk: async () => {
          try {
            await adminDeleteCourse(course.id);
            message.success("课程已删除");
            await refreshCurrentData();
          } catch (error) {
            message.error(toErrorMessage(error, "删除课程失败"));
          }
        },
      });
    },
    [refreshCurrentData],
  );

  const columns: TableColumnsType<AdminCourse> = useMemo(
    () => [
      {
        title: "课程名称",
        dataIndex: "name",
        ellipsis: true,
      },
      {
        title: "课程码",
        dataIndex: "courseCode",
        width: 120,
        render: (code: string) => (
          <Typography.Text code className="text-sm tracking-wider">
            {code}
          </Typography.Text>
        ),
      },
      {
        title: "授课教师",
        dataIndex: "teacherName",
        width: 140,
        render: (name: string | null) => name || "-",
      },
      {
        title: "学生数",
        dataIndex: "studentCount",
        width: 100,
        align: "center",
      },
      {
        title: "课程状态",
        dataIndex: "status",
        width: 100,
        render: (status: CourseStatus) => {
          const info = getCourseStatusTagInfo(status);
          return <Tag color={info.color}>{info.label}</Tag>;
        },
      },
      {
        title: "创建时间",
        dataIndex: "createdAt",
        width: 160,
        render: (value: string) => formatDateTime(value),
      },
      {
        title: "操作",
        key: "actions",
        width: 300,
        fixed: "right",
        render: (_: unknown, record) => (
          <Space size="small" wrap>
            <Button
              type="link"
              size="small"
              onClick={() => navigate(`/admin/courses/${record.id}`)}
            >
              详情
            </Button>
            <Button
              type="link"
              size="small"
              onClick={() => {
                setEditCourse(record);
                editForm.setFieldsValue({
                  name: record.name,
                  description: record.description || undefined,
                });
              }}
            >
              编辑
            </Button>
            {record.status === "active" ? (
              <Button
                type="link"
                size="small"
                onClick={() => void handleArchive(record)}
              >
                归档
              </Button>
            ) : (
              <Button
                type="link"
                size="small"
                onClick={() => void handleRestore(record)}
              >
                恢复
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
    [editForm, handleArchive, handleDelete, handleRestore, navigate],
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
            placeholder="搜索课程名/教师名/课程码"
          />
        </Form.Item>
        <Form.Item name="status" className="min-w-[132px]">
          <Select allowClear placeholder="课程状态" options={STATUS_OPTIONS} />
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
        <CommonTable<AdminCourse>
          columns={columns}
          dataSource={courses}
          rowKey="id"
          loading={tableLoading}
          scroll={{ x: 1200 }}
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
          empty={{ title: "暂无课程数据" }}
        />
      </div>

      {/* 编辑课程弹窗 */}
      <Modal
        title="编辑课程"
        open={Boolean(editCourse)}
        onCancel={() => setEditCourse(null)}
        onOk={() => void handleEdit()}
        confirmLoading={submittingEdit}
        okText="保存"
        cancelText="取消"
        destroyOnHidden
      >
        <Form<EditFormValues>
          form={editForm}
          layout="vertical"
          requiredMark={false}
        >
          <Form.Item
            name="name"
            label="课程名称"
            rules={[
              { required: true, message: "请输入课程名称" },
              { max: 100, message: "最多 100 字" },
            ]}
          >
            <Input placeholder="请输入课程名称" />
          </Form.Item>
          <Form.Item name="description" label="课程简介">
            <Input.TextArea rows={3} placeholder="可选" />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
}
