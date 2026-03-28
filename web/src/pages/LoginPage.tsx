import {
  BookOutlined,
  LockOutlined,
  MailOutlined,
  ReadOutlined,
  SafetyCertificateOutlined,
  UserOutlined,
} from "@ant-design/icons";
import { Alert, Button, Card, Form, Input, Segmented, Typography } from "antd";
import { useNavigate } from "react-router";
import { useEffect, useState } from "react";
import type { User } from "@supabase/supabase-js";
import {
  ensureProfileForUser,
  extractRoleFromMetadata,
  getRoleRedirectPath,
  resolveCurrentProfileWithRetry,
} from "@/lib/profile";
import { getSupabaseClient } from "@/lib/supabase";
import { useAuthStore, type UserRole } from "@/store/authStore";
import styles from "@/styles/login.module.css";

type AuthMode = "login" | "signup";
type SignupRole = Exclude<UserRole, "admin">;

interface LoginFormValues {
  email: string;
  password: string;
}

interface SignupFormValues {
  displayName?: string;
  email: string;
  password: string;
  confirmPassword: string;
  role: SignupRole;
}

function mapSignupErrorMessage(rawMessage: string): string {
  const lowered = rawMessage.toLowerCase();

  if (
    lowered.includes("already registered") ||
    lowered.includes("already exists") ||
    lowered.includes("该邮箱已注册")
  ) {
    return "该邮箱已注册，请直接登录";
  }

  if (rawMessage.includes("密码至少 8 位") || lowered.includes("password") && lowered.includes("8")) {
    return "密码至少 8 位";
  }

  if (rawMessage.includes("邮箱格式不正确") || (lowered.includes("email") && lowered.includes("invalid"))) {
    return "邮箱格式不正确";
  }

  return rawMessage || "注册失败";
}

function isEmailConfirmationRequired(rawMessage: string): boolean {
  const lowered = rawMessage.toLowerCase();
  return (
    lowered.includes("email not confirmed") ||
    lowered.includes("email_not_confirmed") ||
    lowered.includes("confirm your email")
  );
}

export default function LoginPage() {
  const navigate = useNavigate();
  const setUser = useAuthStore((state) => state.setUser);
  const [authMode, setAuthMode] = useState<AuthMode>("login");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [loginForm] = Form.useForm<LoginFormValues>();
  const [signupForm] = Form.useForm<SignupFormValues>();

  const isSignup = authMode === "signup";

  useEffect(() => {
    if (!isSignup) {
      return;
    }

    const role = signupForm.getFieldValue("role");
    if (role !== "student" && role !== "teacher") {
      signupForm.setFieldValue("role", "student");
    }
  }, [isSignup, signupForm]);

  const persistAndNavigate = async (user: User, fallbackRole: UserRole) => {
    const { profile, role } = await resolveCurrentProfileWithRetry(fallbackRole, 2);
    const email = profile?.email ?? user.email ?? "";

    setUser({
      id: user.id,
      email,
      role,
      displayName: profile?.displayName ?? null,
      avatarUrl: profile?.avatarUrl ?? null,
    });

    if (typeof window !== "undefined") {
      window.localStorage.setItem("selected-role", role);
    }

    navigate(getRoleRedirectPath(role));
  };

  const handleLogin = async (values: LoginFormValues) => {
    setLoading(true);
    setError(null);
    setNotice(null);

    try {
      const supabase = getSupabaseClient();
      const { data, error: authError } = await supabase.auth.signInWithPassword({
        email: values.email.trim(),
        password: values.password,
      });

      if (authError || !data.user) {
        throw new Error(authError?.message ?? "登录失败");
      }

      const metadataRole = extractRoleFromMetadata(data.user.user_metadata);
      await persistAndNavigate(data.user, metadataRole ?? "student");
    } catch (err) {
      setError(err instanceof Error ? err.message : "登录失败");
    } finally {
      setLoading(false);
    }
  };

  const handleSignup = async (values: SignupFormValues) => {
    setLoading(true);
    setError(null);
    setNotice(null);

    if (values.password !== values.confirmPassword) {
      setError("两次输入的密码不一致");
      setLoading(false);
      return;
    }

    try {
      const supabase = getSupabaseClient();
      const email = values.email.trim();
      const displayName = values.displayName?.trim();
      const role = values.role;

      const { data: signupData, error: signupError } = await supabase.auth.signUp({
        email,
        password: values.password,
        options: {
          data: {
            role,
            display_name: displayName || undefined,
          },
        },
      });

      if (signupError || !signupData.user) {
        throw new Error(mapSignupErrorMessage(signupError?.message ?? "注册失败"));
      }

      let authUser: User | null = signupData.session?.user ?? null;

      if (!authUser) {
        const { data: signinData, error: signinError } = await supabase.auth.signInWithPassword({
          email,
          password: values.password,
        });

        if (signinError || !signinData.user) {
          const signinMessage = signinError?.message ?? "";

          if (isEmailConfirmationRequired(signinMessage)) {
            setAuthMode("login");
            loginForm.setFieldValue("email", email);
            setNotice("注册成功，请先前往邮箱完成验证，再返回登录。");
            return;
          }

          throw new Error("注册成功，但自动登录失败，请手动登录");
        }

        authUser = signinData.user;
      }

      if (!authUser) {
        throw new Error("注册成功，但自动登录失败，请手动登录");
      }

      await ensureProfileForUser(authUser, {
        role,
        displayName,
      });
      await persistAndNavigate(authUser, role);
    } catch (err) {
      setError(err instanceof Error ? err.message : "注册失败");
    } finally {
      setLoading(false);
    }
  };

  return (
    <main className={styles.shell}>
      <section className={styles.brandPane}>
        <div className={styles.brandHeader}>
          <span className={styles.brandMark}>AI</span>
          <span className={styles.brandName}>AI Teaching System</span>
        </div>

        <span className={styles.badge}>Live Resolution</span>
        <Typography.Title level={1} className={styles.brandTitle}>
          Intelligent automation
          <br />
          for modern classrooms.
        </Typography.Title>
        <Typography.Paragraph className={styles.brandDescription}>
          面向教师与学生的 AI 教学工作台，支持课程讲解、练习反馈与过程追踪。
        </Typography.Paragraph>

        <div className={styles.featureList}>
          <div className={styles.featureItem}>
            <SafetyCertificateOutlined />
            <span>注册后自动建立个人 Profile</span>
          </div>
          <div className={styles.featureItem}>
            <BookOutlined />
            <span>老师端与学生端自动按身份分流</span>
          </div>
          <div className={styles.featureItem}>
            <ReadOutlined />
            <span>学习轨迹与课堂任务统一管理</span>
          </div>
        </div>
      </section>

      <section className={styles.formPane}>
        <div className={styles.mobileBrand}>
          <span className={styles.brandMark}>AI</span>
          <span className={styles.mobileBrandName}>AI Teaching System</span>
        </div>

        <div className={styles.formWrap}>
          <Card className={styles.authCard} bordered={false}>
            {!isSignup ? (
              <div className={styles.step}>
                <div className={styles.titleBlock}>
                  <h1 className={styles.formTitle}>欢迎回来</h1>
                  <p className={styles.formDescription}>登录你的账号</p>
                </div>

                {error ? (
                  <Alert
                    type="error"
                    showIcon
                    closable
                    className={styles.notice}
                    message={error}
                    onClose={() => setError(null)}
                  />
                ) : null}

                {notice ? (
                  <Alert
                    type="success"
                    showIcon
                    closable
                    className={styles.notice}
                    message={notice}
                    onClose={() => setNotice(null)}
                  />
                ) : null}

                <Form<LoginFormValues>
                  form={loginForm}
                  layout="vertical"
                  onFinish={handleLogin}
                  requiredMark={false}
                >
                  <Form.Item
                    label={<span className={styles.fieldLabel}>邮箱</span>}
                    name="email"
                    rules={[
                      { required: true, message: "请输入邮箱" },
                      { type: "email", message: "邮箱格式不正确" },
                    ]}
                  >
                    <Input
                      prefix={<MailOutlined />}
                      placeholder="请输入邮箱"
                      autoComplete="email"
                      className={styles.fieldInput}
                    />
                  </Form.Item>

                  <Form.Item
                    label={<span className={styles.fieldLabel}>密码</span>}
                    name="password"
                    rules={[{ required: true, message: "请输入密码" }]}
                  >
                    <Input.Password
                      prefix={<LockOutlined />}
                      placeholder="请输入密码"
                      autoComplete="current-password"
                      className={styles.fieldInput}
                    />
                  </Form.Item>

                  <Form.Item>
                    <Button htmlType="submit" type="primary" loading={loading} className={styles.submitButton} block>
                      登录
                    </Button>
                  </Form.Item>
                </Form>

                <div className={styles.bottomSingle}>
                  <span className={styles.mutedText}>还没有账号？</span>
                  <button
                    type="button"
                    onClick={() => {
                      setAuthMode("signup");
                      signupForm.setFieldValue("role", "student");
                      setError(null);
                      setNotice(null);
                    }}
                    className={styles.linkText}
                  >
                    立即注册
                  </button>
                </div>
              </div>
            ) : (
              <div className={styles.step}>
                <div className={styles.titleBlock}>
                  <h1 className={styles.formTitle}>创建账号</h1>
                  <p className={styles.formDescription}>注册后即可开始使用</p>
                </div>

                {error ? (
                  <Alert
                    type="error"
                    showIcon
                    closable
                    className={styles.notice}
                    message={error}
                    onClose={() => setError(null)}
                  />
                ) : null}

                {notice ? (
                  <Alert
                    type="success"
                    showIcon
                    closable
                    className={styles.notice}
                    message={notice}
                    onClose={() => setNotice(null)}
                  />
                ) : null}

                <Form<SignupFormValues>
                  form={signupForm}
                  layout="vertical"
                  onFinish={handleSignup}
                  requiredMark={false}
                  initialValues={{ role: "student" }}
                >
                  <Form.Item
                    label={<span className={styles.fieldLabel}>身份</span>}
                    name="role"
                    initialValue="student"
                    rules={[{ required: true, message: "请选择身份" }]}
                  >
                    <Segmented
                      block
                      className={styles.roleSwitch}
                      onChange={(value) => signupForm.setFieldValue("role", value)}
                      options={[
                        {
                          label: (
                            <span className={styles.roleLabel}>
                              <ReadOutlined />
                              学生
                            </span>
                          ),
                          value: "student",
                        },
                        {
                          label: (
                            <span className={styles.roleLabel}>
                              <BookOutlined />
                              老师
                            </span>
                          ),
                          value: "teacher",
                        },
                      ]}
                    />
                  </Form.Item>

                  <Form.Item label={<span className={styles.fieldLabel}>邮箱</span>} name="email" rules={[
                    { required: true, message: "请输入邮箱" },
                    { type: "email", message: "邮箱格式不正确" },
                  ]}>
                    <Input
                      prefix={<MailOutlined />}
                      placeholder="请输入邮箱"
                      autoComplete="email"
                      className={styles.fieldInput}
                    />
                  </Form.Item>

                  <Form.Item label={<span className={styles.fieldLabel}>昵称（可选）</span>} name="displayName">
                    <Input
                      prefix={<UserOutlined />}
                      placeholder="请输入昵称（可选）"
                      autoComplete="nickname"
                      className={styles.fieldInput}
                    />
                  </Form.Item>

                  <Form.Item
                    label={<span className={styles.fieldLabel}>密码</span>}
                    name="password"
                    rules={[
                      { required: true, message: "请输入密码" },
                      { min: 8, message: "密码至少 8 位" },
                    ]}
                  >
                    <Input.Password
                      prefix={<LockOutlined />}
                      placeholder="请输入密码"
                      autoComplete="new-password"
                      className={styles.fieldInput}
                    />
                  </Form.Item>

                  <Form.Item
                    label={<span className={styles.fieldLabel}>确认密码</span>}
                    name="confirmPassword"
                    dependencies={["password"]}
                    rules={[
                      { required: true, message: "请再次输入密码" },
                      ({ getFieldValue }) => ({
                        validator(_, value) {
                          if (!value || getFieldValue("password") === value) {
                            return Promise.resolve();
                          }
                          return Promise.reject(new Error("两次输入的密码不一致"));
                        },
                      }),
                    ]}
                  >
                    <Input.Password
                      prefix={<LockOutlined />}
                      placeholder="请再次输入密码"
                      autoComplete="new-password"
                      className={styles.fieldInput}
                    />
                  </Form.Item>

                  <Form.Item>
                    <Button htmlType="submit" type="primary" loading={loading} className={styles.submitButton} block>
                      注册
                    </Button>
                  </Form.Item>
                </Form>

                <div className={styles.bottomSingle}>
                  <span className={styles.mutedText}>已有账号？</span>
                  <button
                    type="button"
                    onClick={() => {
                      setAuthMode("login");
                      setError(null);
                      setNotice(null);
                    }}
                    className={styles.linkText}
                  >
                    去登录
                  </button>
                </div>
              </div>
            )}
          </Card>
        </div>
      </section>
    </main>
  );
}
