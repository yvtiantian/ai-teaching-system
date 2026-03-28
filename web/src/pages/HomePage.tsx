import { Spin } from "antd";
import { useNavigate } from "react-router";
import { useEffect } from "react";
import { getRoleRedirectPath } from "@/lib/profile";
import { useAuthStore } from "@/store/authStore";

export default function HomePage() {
  const navigate = useNavigate();
  const user = useAuthStore((state) => state.user);
  const authInitialized = useAuthStore((state) => state.authInitialized);

  useEffect(() => {
    if (!authInitialized) {
      return;
    }

    if (!user) {
      navigate("/login", { replace: true });
      return;
    }

    navigate(getRoleRedirectPath(user.role), { replace: true });
  }, [authInitialized, navigate, user]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-[var(--color-bg-3)] p-6">
      <Spin size="large" />
    </div>
  );
}
