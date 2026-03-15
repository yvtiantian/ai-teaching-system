"use client";

import {
  PlusOutlined,
  ReloadOutlined,
  SearchOutlined,
} from "@ant-design/icons";
import {
  Avatar,
  Button,
  Descriptions,
  Drawer,
  Form,
  Input,
  Modal,
  Select,
  Space,
  Spin,
  Tag,
  Tooltip,
  Typography,
  message,
} from "antd";
import type { TableColumnsType } from "antd";
import dayjs, { type Dayjs } from "dayjs";
import "dayjs/locale/zh-cn";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";
import CommonTable from "@/components/CommonTable/CommonTable";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  createAdminUser,
  listAdminUsers,
  resetAdminUserPassword,
  setAdminUserStatus,
  updateAdminUser,
} from "@/services/adminUsers";
import { useAuthStore } from "@/store/authStore";
import type {
  AdminAccountStatus,
  AdminUser,
  AdminUserListQuery,
  AdminUserRole,
} from "@/types/admin-user";

dayjs.locale("zh-cn");

const PHONE_PATTERN = /^[0-9+\-\s()]{6,20}$/;

const ROLE_OPTIONS: Array<{ label: string; value: AdminUserRole }> = [
  { label: "学生", value: "student" },
  { label: "教师", value: "teacher" },
  { label: "管理员", value: "admin" },
];

const STATUS_OPTIONS: Array<{ label: string; value: AdminAccountStatus }> = [
  { label: "正常", value: "active" },
  { label: "停用", value: "suspended" },
];

interface FilterFormValues {
  keyword?: string;
  role?: AdminUserRole;
  status?: AdminAccountStatus;
  lastLoginRange?: [Dayjs, Dayjs];
}

interface CreateFormValues {
  email: string;
  password: string;
  role: AdminUserRole;
  displayName?: string;
  phone?: string;
}

interface EditFormValues {
  displayName: string;
  phone?: string;
  role: AdminUserRole;
  avatarUrl?: string;
}

interface ResetPasswordFormValues {
  newPassword: string;
  confirmPassword: string;
}

interface QueryState {
  filters: Omit<AdminUserListQuery, "page" | "pageSize">;
  page: number;
  pageSize: number;
}

const DEFAULT_QUERY_STATE: QueryState = {
  filters: {},
  page: 1,
  pageSize: 20,
};

function toErrorMessage(error: unknown, fallback = "操作失败") {
  if (error instanceof Error) {
    return error.message;
  }
  return fallback;
}

function formatRoleLabel(role: AdminUserRole) {
  if (role === "teacher") {
    return "教师";
  }
  if (role === "admin") {
    return "管理员";
  }
  return "学生";
}

function formatStatusLabel(status: AdminAccountStatus) {
  return status === "suspended" ? "停用" : "正常";
}

function formatStatusColor(status: AdminAccountStatus) {
  return status === "suspended" ? "red" : "green";
}

function formatDateTime(value: string | null) {
  if (!value) {
    return "-";
  }
  const parsed = dayjs(value);
  if (!parsed.isValid()) {
    return "-";
  }
  return parsed.format("YYYY-MM-DD HH:mm:ss");
}

function resolveDisplayName(user: AdminUser) {
  const raw = user.displayName?.trim();
  if (raw) {
    return raw;
  }
  const emailPrefix = user.email.split("@")[0]?.trim();
  if (emailPrefix) {
    return emailPrefix;
  }
  return "-";
}

function normalizeFilters(values: FilterFormValues): QueryState["filters"] {
  const keyword = values.keyword?.trim();
  const range = values.lastLoginRange;

  return {
    keyword: keyword || undefined,
    role: values.role || undefined,
    status: values.status || undefined,
    lastLoginStart: range?.[0]?.startOf("day").toISOString(),
    lastLoginEnd: range?.[1]?.endOf("day").toISOString(),
  };
}

export default function AdminUsersPage() {
  const router = useRouter();
  const user = useAuthStore((state) => state.user);
  const authInitialized = useAuthStore((state) => state.authInitialized);

  const [filterForm] = Form.useForm<FilterFormValues>();
  const [createForm] = Form.useForm<CreateFormValues>();
  const [editForm] = Form.useForm<EditFormValues>();
  const [resetPasswordForm] = Form.useForm<ResetPasswordFormValues>();

  const [users, setUsers] = useState<AdminUser[]>([]);
  const [queryState, setQueryState] = useState<QueryState>(DEFAULT_QUERY_STATE);

  const [tableLoading, setTableLoading] = useState(false);
  const [total, setTotal] = useState(0);

  const [createOpen, setCreateOpen] = useState(false);
  const [editUser, setEditUser] = useState<AdminUser | null>(null);
  const [detailUser, setDetailUser] = useState<AdminUser | null>(null);
  const [statusTargetUser, setStatusTargetUser] = useState<AdminUser | null>(null);
  const [statusToSet, setStatusToSet] = useState<AdminAccountStatus>("suspended");
  const [statusReason, setStatusReason] = useState("");
  const [resetTargetUser, setResetTargetUser] = useState<AdminUser | null>(null);

  const [submittingCreate, setSubmittingCreate] = useState(false);
  const [submittingEdit, setSubmittingEdit] = useState(false);
  const [submittingStatus, setSubmittingStatus] = useState(false);
  const [submittingResetPassword, setSubmittingResetPassword] = useState(false);

  const canAccess = authInitialized && user?.role === "admin";

  const loadUsers = useCallback(async (nextQuery: QueryState) => {
    setTableLoading(true);

    try {
      const result = await listAdminUsers({
        ...nextQuery.filters,
        page: nextQuery.page,
        pageSize: nextQuery.pageSize,
      });

      if (result.users.length === 0 && result.total > 0 && nextQuery.page > 1) {
        setQueryState((prev) => ({
          ...prev,
          page: Math.max(prev.page - 1, 1),
        }));
        return;
      }

      setUsers(result.users);
      setTotal(result.total);
    } catch (error) {
      message.error(toErrorMessage(error, "加载用户列表失败"));
      setUsers([]);
      setTotal(0);
    } finally {
      setTableLoading(false);
    }
  }, []);

  const refreshCurrentData = useCallback(async () => {
    await loadUsers(queryState);
  }, [loadUsers, queryState]);

  const openStatusModal = useCallback((target: AdminUser, nextStatus: AdminAccountStatus) => {
    setStatusTargetUser(target);
    setStatusToSet(nextStatus);
    setStatusReason("");
  }, []);

  useEffect(() => {
    if (!authInitialized) {
      return;
    }

    if (!user) {
      router.replace("/login");
      return;
    }

    if (user.role !== "admin") {
      router.replace(getRoleRedirectPath(user.role));
    }
  }, [authInitialized, router, user]);

  useEffect(() => {
    if (!canAccess) {
      return;
    }

    void loadUsers(queryState);
  }, [canAccess, loadUsers, queryState]);

  const columns: TableColumnsType<AdminUser> = useMemo(
    () => [
      {
        title: "用户ID",
        dataIndex: "id",
        render: (id: string) => (
          <Typography.Text copyable={{ text: id }} code>
            {id.slice(0, 8)}...
          </Typography.Text>
        ),
      },
      {
        title: "头像",
        dataIndex: "avatarUrl",
        width: 80,
        render: (_: string | null, record) => (
          <Avatar src={record.avatarUrl || undefined}>
            {resolveDisplayName(record).charAt(0).toUpperCase()}
          </Avatar>
        ),
      },
      {
        title: "显示名称",
        dataIndex: "displayName",
        width: 160,
        render: (_: string | null, record) => resolveDisplayName(record),
      },
      {
        title: "邮箱",
        dataIndex: "email",
        width: 220,
      },
      {
        title: "角色",
        dataIndex: "role",
        width: 110,
        render: (role: AdminUserRole) => {
          const color = role === "admin" ? "purple" : role === "teacher" ? "blue" : "default";
          return <Tag color={color}>{formatRoleLabel(role)}</Tag>;
        },
      },
      {
        title: "账号状态",
        dataIndex: "accountStatus",
        width: 110,
        render: (status: AdminAccountStatus) => (
          <Tag color={formatStatusColor(status)}>{formatStatusLabel(status)}</Tag>
        ),
      },
      {
        title: "手机号",
        dataIndex: "phone",
        width: 160,
        render: (phone: string | null) => phone || "-",
      },
      {
        title: "注册时间",
        dataIndex: "createdAt",
        width: 180,
        render: (value: string) => formatDateTime(value),
      },
      {
        title: "操作",
        key: "actions",
        width: 260,
        fixed: "right",
        render: (_: unknown, record) => (
          <Space size="small" wrap>
            <Button
              type="link"
              size="small"
              onClick={() => setDetailUser(record)}
            >
              详情
            </Button>
            <Button
              type="link"
              size="small"
              onClick={() => {
                setEditUser(record);
                editForm.setFieldsValue({
                  displayName: resolveDisplayName(record),
                  phone: record.phone || undefined,
                  role: record.role,
                  avatarUrl: record.avatarUrl || undefined,
                });
              }}
            >
              编辑
            </Button>

            {record.accountStatus === "active" ? (
              <Tooltip title={record.id === user?.id ? "不能停用自己" : undefined}>
                <Button
                  type="link"
                  size="small"
                  danger
                  disabled={record.id === user?.id}
                  onClick={() => openStatusModal(record, "suspended")}
                >
                  停用
                </Button>
              </Tooltip>
            ) : (
              <Button
                type="link"
                size="small"
                onClick={() => openStatusModal(record, "active")}
              >
                恢复
              </Button>
            )}

            <Button
              type="link"
              size="small"
              onClick={() => {
                setResetTargetUser(record);
                resetPasswordForm.resetFields();
              }}
            >
              重置密码
            </Button>
          </Space>
        ),
      },
    ],
    [editForm, openStatusModal, resetPasswordForm, user?.id]
  );

  const handleSearch = (values: FilterFormValues) => {
    setQueryState((prev) => ({
      ...prev,
      page: 1,
      filters: normalizeFilters(values),
    }));
  };

  const handleReset = () => {
    filterForm.resetFields();
    setQueryState({
      filters: {},
      page: 1,
      pageSize: 20,
    });
  };

  const handleCreate = async () => {
    try {
      const values = await createForm.validateFields();
      setSubmittingCreate(true);

      await createAdminUser({
        email: values.email,
        password: values.password,
        role: values.role,
        displayName: values.displayName?.trim() || null,
        phone: values.phone?.trim() || null,
      });

      message.success("用户创建成功");
      setCreateOpen(false);
      createForm.resetFields();
      await refreshCurrentData();
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) {
        return;
      }
      message.error(toErrorMessage(error, "创建用户失败"));
    } finally {
      setSubmittingCreate(false);
    }
  };

  const handleEdit = async () => {
    if (!editUser) {
      return;
    }

    try {
      const values = await editForm.validateFields();
      setSubmittingEdit(true);

      await updateAdminUser(editUser.id, {
        displayName: values.displayName,
        phone: values.phone?.trim() || null,
        role: values.role,
        avatarUrl: values.avatarUrl?.trim() || null,
      });

      message.success("用户信息已更新");
      setEditUser(null);
      await refreshCurrentData();
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) {
        return;
      }
      message.error(toErrorMessage(error, "更新用户失败"));
    } finally {
      setSubmittingEdit(false);
    }
  };

  const handleSetStatus = async () => {
    if (!statusTargetUser) {
      return;
    }

    if (statusToSet === "suspended" && !statusReason.trim()) {
      message.error("停用时必须填写原因");
      return;
    }

    try {
      setSubmittingStatus(true);

      await setAdminUserStatus(statusTargetUser.id, {
        status: statusToSet,
        reason: statusToSet === "suspended" ? statusReason : null,
      });

      message.success(statusToSet === "suspended" ? "账号已停用" : "账号已恢复");
      setStatusTargetUser(null);
      setStatusReason("");
      await refreshCurrentData();
    } catch (error) {
      message.error(toErrorMessage(error, "更新账号状态失败"));
    } finally {
      setSubmittingStatus(false);
    }
  };

  const handleResetPassword = async () => {
    if (!resetTargetUser) {
      return;
    }

    try {
      const values = await resetPasswordForm.validateFields();
      setSubmittingResetPassword(true);

      await resetAdminUserPassword(resetTargetUser.id, {
        newPassword: values.newPassword,
      });

      message.success("密码已重置");
      setResetTargetUser(null);
      resetPasswordForm.resetFields();
    } catch (error) {
      if (error && typeof error === "object" && "errorFields" in error) {
        return;
      }
      message.error(toErrorMessage(error, "重置密码失败"));
    } finally {
      setSubmittingResetPassword(false);
    }
  };

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
            placeholder="搜索邮箱/显示名/手机号"
          />
        </Form.Item>

        <Form.Item name="role" className="min-w-[132px]">
          <Select allowClear placeholder="角色" options={ROLE_OPTIONS} />
        </Form.Item>

        <Form.Item name="status" className="min-w-[132px]">
          <Select allowClear placeholder="状态" options={STATUS_OPTIONS} />
        </Form.Item>

        <Form.Item>
          <Space>
            <Button type="primary" htmlType="submit">
              查询
            </Button>
            <Button onClick={handleReset}>重置</Button>
            <Button icon={<ReloadOutlined />} onClick={() => void refreshCurrentData()}>
              刷新
            </Button>
            <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateOpen(true)}>
              新增用户
            </Button>
          </Space>
        </Form.Item>
      </Form>

      <div className="flex-1 min-h-0 mt-2">
        <CommonTable<AdminUser>
          columns={columns}
          dataSource={users}
          rowKey="id"
          loading={tableLoading}
          scroll={{ x: 1500 }}
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
          empty={{ title: "暂无用户数据" }}
        />
      </div>

      <Modal
        title="新增用户"
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
          initialValues={{ role: "student" }}
          requiredMark={false}
        >
          <Form.Item
            name="email"
            label="邮箱"
            rules={[
              { required: true, message: "请输入邮箱" },
              { type: "email", message: "邮箱格式不正确" },
            ]}
          >
            <Input placeholder="请输入邮箱" />
          </Form.Item>

          <Form.Item
            name="password"
            label="初始密码"
            rules={[{ required: true, message: "请输入初始密码" }, { min: 8, message: "密码至少 8 位" }]}
          >
            <Input.Password placeholder="请输入初始密码" />
          </Form.Item>

          <Form.Item name="role" label="角色" rules={[{ required: true, message: "请选择角色" }]}>
            <Select options={ROLE_OPTIONS} />
          </Form.Item>

          <Form.Item name="displayName" label="显示名称">
            <Input placeholder="可选，留空时按邮箱前缀展示" />
          </Form.Item>

          <Form.Item
            name="phone"
            label="手机号"
            rules={[
              {
                validator: (_, value: string | undefined) => {
                  if (!value || !value.trim()) {
                    return Promise.resolve();
                  }
                  if (!PHONE_PATTERN.test(value.trim())) {
                    return Promise.reject(new Error("手机号格式不正确"));
                  }
                  return Promise.resolve();
                },
              },
            ]}
          >
            <Input placeholder="可选" />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        title="编辑用户"
        open={Boolean(editUser)}
        onCancel={() => setEditUser(null)}
        onOk={() => void handleEdit()}
        confirmLoading={submittingEdit}
        okText="保存"
        cancelText="取消"
        destroyOnHidden
      >
        <Form<EditFormValues> form={editForm} layout="vertical" requiredMark={false}>
          <Form.Item
            name="displayName"
            label="显示名称"
            rules={[{ required: true, message: "请输入显示名称" }, { max: 50, message: "最多 50 字" }]}
          >
            <Input placeholder="请输入显示名称" />
          </Form.Item>

          <Form.Item
            name="phone"
            label="手机号"
            rules={[
              {
                validator: (_, value: string | undefined) => {
                  if (!value || !value.trim()) {
                    return Promise.resolve();
                  }
                  if (!PHONE_PATTERN.test(value.trim())) {
                    return Promise.reject(new Error("手机号格式不正确"));
                  }
                  return Promise.resolve();
                },
              },
            ]}
          >
            <Input placeholder="可为空" />
          </Form.Item>

          <Form.Item name="role" label="角色" rules={[{ required: true, message: "请选择角色" }]}>
            <Select
              options={ROLE_OPTIONS}
              disabled={editUser?.id === user.id}
              placeholder={editUser?.id === user.id ? "不能修改自己的角色" : "请选择角色"}
            />
          </Form.Item>

          <Form.Item
            name="avatarUrl"
            label="头像 URL"
            rules={[{ type: "url", warningOnly: true, message: "建议填写合法 URL" }]}
          >
            <Input placeholder="可为空" />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        title={statusToSet === "suspended" ? "停用账号" : "恢复账号"}
        open={Boolean(statusTargetUser)}
        onCancel={() => {
          setStatusTargetUser(null);
          setStatusReason("");
        }}
        onOk={() => void handleSetStatus()}
        confirmLoading={submittingStatus}
        okText={statusToSet === "suspended" ? "确认停用" : "确认恢复"}
        okButtonProps={{ danger: statusToSet === "suspended" }}
        cancelText="取消"
        destroyOnHidden
        centered
      >
        <div className="space-y-3">
          <Typography.Text>
            {statusToSet === "suspended"
              ? `将停用账号 ${statusTargetUser?.email || ""}。停用后该用户将无法继续使用系统。`
              : `将恢复账号 ${statusTargetUser?.email || ""}。恢复后该用户可重新使用系统。`}
          </Typography.Text>

          {statusToSet === "suspended" ? (
            <div>
              <Input.TextArea
                value={statusReason}
                onChange={(event) => setStatusReason(event.target.value)}
                rows={4}
                maxLength={200}
                showCount={false}
                placeholder="请输入停用原因（必填）"
              />
              <div className="mt-1 text-right text-xs text-[var(--color-text-3)]">
                {statusReason.length} / 200
              </div>
            </div>
          ) : null}
        </div>
      </Modal>

      <Modal
        title="重置密码"
        open={Boolean(resetTargetUser)}
        onCancel={() => {
          setResetTargetUser(null);
          resetPasswordForm.resetFields();
        }}
        onOk={() => void handleResetPassword()}
        confirmLoading={submittingResetPassword}
        okText="确认重置"
        cancelText="取消"
        destroyOnHidden
      >
        <Form<ResetPasswordFormValues>
          form={resetPasswordForm}
          layout="vertical"
          requiredMark={false}
        >
          <Typography.Paragraph className="!mb-3">
            将为账号 {resetTargetUser?.email || ""} 设置新密码。
          </Typography.Paragraph>

          <Form.Item
            name="newPassword"
            label="新密码"
            rules={[
              { required: true, message: "请输入新密码" },
              { min: 8, message: "密码至少 8 位" },
            ]}
          >
            <Input.Password placeholder="请输入新密码" />
          </Form.Item>

          <Form.Item
            name="confirmPassword"
            label="确认新密码"
            dependencies={["newPassword"]}
            rules={[
              { required: true, message: "请再次输入新密码" },
              ({ getFieldValue }) => ({
                validator(_, value: string | undefined) {
                  if (!value || getFieldValue("newPassword") === value) {
                    return Promise.resolve();
                  }
                  return Promise.reject(new Error("两次输入的密码不一致"));
                },
              }),
            ]}
          >
            <Input.Password placeholder="请再次输入新密码" />
          </Form.Item>
        </Form>
      </Modal>

      <Drawer
        title="用户详情"
        open={Boolean(detailUser)}
        width={520}
        onClose={() => setDetailUser(null)}
      >
        {detailUser ? (
          <Descriptions column={1} size="small" bordered>
            <Descriptions.Item label="用户ID">
              <Typography.Text copyable={{ text: detailUser.id }}>{detailUser.id}</Typography.Text>
            </Descriptions.Item>
            <Descriptions.Item label="头像">
              <Avatar src={detailUser.avatarUrl || undefined} size={48}>
                {resolveDisplayName(detailUser).charAt(0).toUpperCase()}
              </Avatar>
            </Descriptions.Item>
            <Descriptions.Item label="显示名称">{resolveDisplayName(detailUser)}</Descriptions.Item>
            <Descriptions.Item label="邮箱">
              <Typography.Text copyable={{ text: detailUser.email }}>{detailUser.email}</Typography.Text>
            </Descriptions.Item>
            <Descriptions.Item label="角色">{formatRoleLabel(detailUser.role)}</Descriptions.Item>
            <Descriptions.Item label="账号状态">
              <Tag color={formatStatusColor(detailUser.accountStatus)}>
                {formatStatusLabel(detailUser.accountStatus)}
              </Tag>
            </Descriptions.Item>
            <Descriptions.Item label="状态原因">{detailUser.statusReason || "-"}</Descriptions.Item>
            <Descriptions.Item label="手机号">{detailUser.phone || "-"}</Descriptions.Item>
            <Descriptions.Item label="注册时间">{formatDateTime(detailUser.createdAt)}</Descriptions.Item>
            <Descriptions.Item label="更新时间">{formatDateTime(detailUser.updatedAt)}</Descriptions.Item>
          </Descriptions>
        ) : null}
      </Drawer>
    </div>
  );
}
