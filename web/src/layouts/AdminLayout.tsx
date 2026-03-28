import { Outlet } from "react-router";
import { ReadOutlined, TeamOutlined } from "@ant-design/icons";
import RoleDashboardLayout from "@/components/layout/RoleDashboardLayout";

export default function AdminLayout() {
  return (
    <RoleDashboardLayout
      title="AI Teaching Studio"
      menuItems={[
        {
          key: "users",
          href: "/admin/users",
          label: "人员管理",
          icon: <TeamOutlined />,
        },
        {
          key: "courses",
          href: "/admin/courses",
          label: "课程管理",
          icon: <ReadOutlined />,
        },
      ]}
    >
      <Outlet />
    </RoleDashboardLayout>
  );
}
