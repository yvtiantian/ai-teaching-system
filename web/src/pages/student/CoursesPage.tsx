import {
  LoginOutlined,
  LogoutOutlined,
  ReloadOutlined,
} from "@ant-design/icons";
import {
  Button,
  Form,
  Input,
  Modal,
  Space,
  Spin,
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
  studentJoinCourse,
  studentLeaveCourse,
  studentListCourses,
} from "@/services/studentCourses";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, formatDateTime } from "@/lib/utils";
import type { StudentCourse } from "@/types/course";

dayjs.locale("zh-cn");

interface JoinFormValues {
  courseCode: string;
}

export default function StudentCoursesPage() {
  const navigate = useNavigate();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [courses, setCourses] = useState<StudentCourse[]>([]);
  const [loading, setLoading] = useState(false);

  const [joinOpen, setJoinOpen] = useState(false);
  const [joinForm] = Form.useForm<JoinFormValues>();
  const [submittingJoin, setSubmittingJoin] = useState(false);

  const canAccess = authInitialized && user?.role === "student";

  const loadCourses = useCallback(async () => {
    setLoading(true);
    try {
      const data = await studentListCourses();
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
    if (user.role !== "student") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (canAccess) void loadCourses();
  }, [canAccess, loadCourses]);

  const handleJoin = async () => {
    try {
      const values = await joinForm.validateFields();
      setSubmittingJoin(true);
      const result = await studentJoinCourse(values.courseCode);
      message.success(`已加入「${result.courseName}」`);
      setJoinOpen(false);
      joinForm.resetFields();
      await loadCourses();
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) return;
      message.error(toErrorMessage(error, "加入课程失败"));
    } finally {
      setSubmittingJoin(false);
    }
  };

  const handleLeave = useCallback(
    (course: StudentCourse) => {
      Modal.confirm({
        title: "退出课程",
        content: `确定退出「${course.courseName}」？`,
        okText: "退出",
        okType: "danger",
        cancelText: "取消",
        onOk: async () => {
          try {
            await studentLeaveCourse(course.courseId);
            message.success("已退出课程");
            await loadCourses();
          } catch (error) {
            message.error(toErrorMessage(error, "退出课程失败"));
          }
        },
      });
    },
    [loadCourses],
  );

  const columns: TableColumnsType<StudentCourse> = useMemo(
    () => [
      {
        title: "课程名称",
        dataIndex: "courseName",
        width: 220,
        ellipsis: true,
      },
      {
        title: "授课教师",
        dataIndex: "teacherName",
        width: 150,
        render: (name: string | null) => name || "-",
      },
      {
        title: "课程简介",
        dataIndex: "courseDescription",
        width: 260,
        ellipsis: true,
        render: (desc: string | null) => desc || "-",
      },
      {
        title: "加入时间",
        dataIndex: "enrolledAt",
        width: 160,
        render: (value: string) => formatDateTime(value),
      },
      {
        title: "操作",
        key: "actions",
        width: 100,
        render: (_: unknown, record) => (
          <Button
            type="link"
            size="small"
            danger
            icon={<LogoutOutlined />}
            onClick={() => handleLeave(record)}
          >
            退出
          </Button>
        ),
      },
    ],
    [handleLeave],
  );

  if (!authInitialized || !user || user.role !== "student") {
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
          <Button type="primary" icon={<LoginOutlined />} onClick={() => setJoinOpen(true)}>
            加入课程
          </Button>
        </Space>
      </div>

      <div className="flex-1 min-h-0">
        <CommonTable<StudentCourse>
          columns={columns}
          dataSource={courses}
          rowKey="courseId"
          loading={loading}
          scroll={{ x: 800 }}
          empty={{ title: "暂无课程，点击「加入课程」输入课程码" }}
        />
      </div>

      {/* 加入课程弹窗 */}
      <Modal
        title="加入课程"
        open={joinOpen}
        onCancel={() => {
          setJoinOpen(false);
          joinForm.resetFields();
        }}
        onOk={() => void handleJoin()}
        confirmLoading={submittingJoin}
        okText="加入"
        cancelText="取消"
        destroyOnHidden
      >
        <Form<JoinFormValues>
          form={joinForm}
          layout="vertical"
          requiredMark={false}
        >
          <Form.Item
            name="courseCode"
            label="课程码"
            rules={[
              { required: true, message: "请输入课程码" },
              {
                pattern: /^[A-Za-z0-9]{6}$/,
                message: "课程码为 6 位字母或数字",
              },
            ]}
            normalize={(value: string) => value?.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6)}
          >
            <Input
              placeholder="请输入 6 位课程码"
              maxLength={6}
              className="tracking-widest text-center text-lg"
              autoComplete="off"
            />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
}
