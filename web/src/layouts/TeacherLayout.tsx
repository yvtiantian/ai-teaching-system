import { Outlet } from "react-router";
import { BarChartOutlined, FormOutlined, ReadOutlined } from "@ant-design/icons";
import RoleDashboardLayout from "@/components/layout/RoleDashboardLayout";

export default function TeacherLayout() {
  return (
    <RoleDashboardLayout
      title="AI Teaching Studio"
      menuItems={[
        {
          key: "dashboard",
          href: "/teacher/learn",
          label: "教学辅助智能体",
          icon: <BarChartOutlined />,
        },
        {
          key: "courses",
          href: "/teacher/courses",
          label: "我的课程",
          icon: <ReadOutlined />,
        },
        {
          key: "assignments",
          href: "/teacher/assignments",
          label: "布置作业",
          icon: <FormOutlined />,
        },
      ]}
    >
      <Outlet />
    </RoleDashboardLayout>
  );
}
