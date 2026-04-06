import {
  CopyOutlined,
  EditOutlined,
  PlusOutlined,
  ReloadOutlined,
  SyncOutlined,
} from "@ant-design/icons";
import {
  Button,
  Form,
  Input,
  Modal,
  Space,
  Spin,
  Tag,
  Tooltip,
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
  teacherArchiveCourse,
  teacherCreateCourse,
  teacherListCourses,
  teacherRegenerateCode,
  teacherRestoreCourse,
  teacherUpdateCourse,
} from "@/services/teacherCourses";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, formatDateTime } from "@/lib/utils";
import type { CourseStatus, TeacherCourse } from "@/types/course";

dayjs.locale("zh-cn");

interface CreateFormValues {
  name: string;
  description?: string;
}

interface EditFormValues {
  name: string;
  description?: string;
}

export default function TeacherCoursesPage() {
  const navigate = useNavigate();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [courses, setCourses] = useState<TeacherCourse[]>([]);
  const [loading, setLoading] = useState(false);

  const [createOpen, setCreateOpen] = useState(false);
  const [createForm] = Form.useForm<CreateFormValues>();
  const [submittingCreate, setSubmittingCreate] = useState(false);

  const [editCourse, setEditCourse] = useState<TeacherCourse | null>(null);
  const [editForm] = Form.useForm<EditFormValues>();
  const [submittingEdit, setSubmittingEdit] = useState(false);

  const canAccess = authInitialized && user?.role === "teacher";

  const loadCourses = useCallback(async () => {
    setLoading(true);
    try {
      const data = await teacherListCourses();
      setCourses(data);
    } catch (error) {
      message.error(toErrorMessage(error, "加载课程列表失败"));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "teacher") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (canAccess) void loadCourses();
  }, [canAccess, loadCourses]);

  const handleCopyCode = useCallback((code: string) => {
    void navigator.clipboard.writeText(code).then(() => {
      message.success("课程码已复制");
    });
  }, []);

  const handleCreate = async () => {
    try {
      const values = await createForm.validateFields();
      setSubmittingCreate(true);
      await teacherCreateCourse({
        name: values.name,
        description: values.description || null,
      });
      message.success("课程创建成功");
      setCreateOpen(false);
      createForm.resetFields();
      await loadCourses();
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) return;
      message.error(toErrorMessage(error, "创建课程失败"));
    } finally {
      setSubmittingCreate(false);
    }
  };

  const handleEdit = async () => {
    if (!editCourse) return;
    try {
      const values = await editForm.validateFields();
      setSubmittingEdit(true);
      await teacherUpdateCourse(editCourse.id, {
        name: values.name,
        description: values.description || null,
      });
      message.success("课程信息已更新");
      setEditCourse(null);
      await loadCourses();
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) return;
      message.error(toErrorMessage(error, "更新课程失败"));
    } finally {
      setSubmittingEdit(false);
    }
  };

  const handleArchive = useCallback(
    (course: TeacherCourse) => {
      Modal.confirm({
        title: "归档课程",
        content: `确定归档「${course.name}」？归档后学生将无法通过课程码加入。`,
        okText: "归档",
        cancelText: "取消",
        onOk: async () => {
          try {
            await teacherArchiveCourse(course.id);
            message.success("课程已归档");
            await loadCourses();
          } catch (error) {
            message.error(toErrorMessage(error, "归档课程失败"));
          }
        },
      });
    },
    [loadCourses],
  );

  const handleRestore = useCallback(
    async (course: TeacherCourse) => {
      try {
        await teacherRestoreCourse(course.id);
        message.success("课程已恢复");
        await loadCourses();
      } catch (error) {
        message.error(toErrorMessage(error, "恢复课程失败"));
      }
    },
    [loadCourses],
  );

  const handleRegenerateCode = useCallback(
    (course: TeacherCourse) => {
      Modal.confirm({
        title: "重新生成课程码",
        content: `确定重新生成「${course.name}」的课程码？旧课程码将立即失效。`,
        okText: "确定",
        cancelText: "取消",
        onOk: async () => {
          try {
            const newCode = await teacherRegenerateCode(course.id);
            message.success(`新课程码：${newCode}`);
            await loadCourses();
          } catch (error) {
            message.error(toErrorMessage(error, "重新生成课程码失败"));
          }
        },
      });
    },
    [loadCourses],
  );

  const columns: TableColumnsType<TeacherCourse> = useMemo(
    () => [
      {
        title: "课程名称",
        dataIndex: "name",
        ellipsis: true,
      },
      {
        title: "课程码",
        dataIndex: "courseCode",
        width: 140,
        render: (code: string) => (
          <Space size={4}>
            <Typography.Text code className="text-sm tracking-wider">
              {code}
            </Typography.Text>
            <Tooltip title="复制课程码">
              <Button
                type="text"
                size="small"
                icon={<CopyOutlined />}
                onClick={() => handleCopyCode(code)}
              />
            </Tooltip>
          </Space>
        ),
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
        width: 280,
        fixed: "right",
        render: (_: unknown, record) => (
          <Space size="small" wrap>
            <Button
              type="link"
              size="small"
              onClick={() => navigate(`/teacher/courses/${record.id}`)}
            >
              详情
            </Button>
            <Button
              type="link"
              size="small"
              icon={<EditOutlined />}
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
            <Button
              type="link"
              size="small"
              icon={<SyncOutlined />}
              onClick={() => handleRegenerateCode(record)}
            >
              换码
            </Button>
            {record.status === "active" ? (
              <Button
                type="link"
                size="small"
                danger
                onClick={() => handleArchive(record)}
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
          </Space>
        ),
      },
    ],
    [editForm, handleArchive, handleCopyCode, handleRegenerateCode, handleRestore, navigate],
  );

  if (!authInitialized || !user || user.role !== "teacher") {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="mb-2 flex items-center justify-between">
        <div />
        <Space>
          <Button icon={<ReloadOutlined />} onClick={() => void loadCourses()}>
            刷新
          </Button>
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateOpen(true)}>
            创建课程
          </Button>
        </Space>
      </div>

      <div className="flex-1 min-h-0">
        <CommonTable<TeacherCourse>
          columns={columns}
          dataSource={courses}
          rowKey="id"
          loading={loading}
          scroll={{ x: 1000 }}
          empty={{ title: "暂无课程，点击「创建课程」开始" }}
        />
      </div>

      {/* 创建课程弹窗 */}
      <Modal
        title="创建课程"
        open={createOpen}
        onCancel={() => {
          setCreateOpen(false);
          createForm.resetFields();
        }}
        onOk={() => void handleCreate()}
        confirmLoading={submittingCreate}
        okText="创建"
        cancelText="取消"
        destroyOnHidden
      >
        <Form<CreateFormValues>
          form={createForm}
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
