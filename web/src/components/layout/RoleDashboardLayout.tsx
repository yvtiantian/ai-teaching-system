import React, { useMemo, useState } from 'react'
import { Layout, Menu, Avatar, Breadcrumb, Dropdown, Modal } from 'antd'
import { HomeOutlined, LogoutOutlined, UserOutlined } from '@ant-design/icons'
import { useNavigate, useLocation } from 'react-router'
import { getSupabaseClient } from '@/lib/supabase'
import { useAuthStore } from '@/store/authStore'
import ProfileContent from '@/components/settings/ProfileContent'
import type { MenuProps } from 'antd'
import type { ReactNode } from 'react'

const { Header, Sider, Content } = Layout

export interface DashboardNavItem {
  key: string
  href: string
  label: string
  icon?: ReactNode
}

interface RoleDashboardLayoutProps {
  title: string
  menuItems: DashboardNavItem[]
  children: ReactNode
}

export default function RoleDashboardLayout({
  title,
  menuItems,
  children,
}: RoleDashboardLayoutProps) {
  const navigate = useNavigate()
  const pathname = useLocation().pathname
  const user = useAuthStore((state) => state.user)
  const clearUser = useAuthStore((state) => state.clearUser)
  const [profileModalOpen, setProfileModalOpen] = useState(false)

  const userName = useMemo(() => {
    if (!user) return '访客'
    if (user.displayName?.trim()) return user.displayName.trim()
    return user.email?.split('@')[0] || '用户'
  }, [user])

  const antdMenuItems: MenuProps['items'] = useMemo(
    () =>
      menuItems.map((item) => ({
        key: item.href,
        icon: item.icon,
        label: item.label,
      })),
    [menuItems]
  )

  const selectedKeys = useMemo(() => {
    const matched = menuItems
      .filter(
        (item) => pathname === item.href || pathname.startsWith(`${item.href}/`)
      )
      .sort((a, b) => b.href.length - a.href.length)
    return matched[0] ? [matched[0].href] : menuItems[0] ? [menuItems[0].href] : []
  }, [menuItems, pathname])

  const handleMenuClick: MenuProps['onClick'] = (e) => {
    const path = e.key
    if (path.startsWith('/')) {
      navigate(path)
    }
  }

  const handleSignOut = async () => {
    try {
      const supabase = getSupabaseClient()
      await supabase.auth.signOut()
    } finally {
      clearUser()
      if (typeof window !== 'undefined') {
        window.localStorage.removeItem('selected-role')
      }
      navigate('/login', { replace: true })
    }
  }

  const userMenuItems: MenuProps['items'] = [
    {
      key: 'profile',
      icon: <UserOutlined />,
      label: '个人消息',
    },
    {
      type: 'divider',
    },
    {
      key: 'logout',
      icon: <LogoutOutlined />,
      label: '退出登录',
      danger: true,
    },
  ]

  const handleUserMenuClick: MenuProps['onClick'] = ({ key }) => {
    if (key === 'profile') {
      setProfileModalOpen(true)
      return
    }

    if (key === 'logout') {
      void handleSignOut()
    }
  }

  const getBreadcrumbItems = () => {
    const items: Array<{ title: React.ReactNode; href?: string }> = [
      { title: <HomeOutlined />, href: menuItems[0]?.href || '/' },
    ]

    const currentItem = menuItems.find(
      (item) => pathname === item.href || pathname.startsWith(`${item.href}/`)
    )

    if (currentItem) {
      items.push({ title: <span>{currentItem.label}</span>, href: currentItem.href })
    }

    return items
  }

  const siderMenu = (
    <Menu
      mode="vertical"
      triggerSubMenuAction="hover"
      selectedKeys={selectedKeys}
      onClick={handleMenuClick}
      items={antdMenuItems}
      className="!border-0 !bg-transparent py-2 custom-menu !text-sm"
    />
  )

  return (
    <Layout className="h-screen flex flex-col overflow-hidden">
      {/* Header */}
      <Header className="dashboard-header !h-14 flex items-center justify-between sticky top-0 z-50 !px-0">
        <div className="flex items-center">
          <div className="flex items-center gap-2.5 pl-6 w-[200px]">
            <div className="w-7 h-7 rounded-lg bg-[var(--color-primary)] flex items-center justify-center flex-shrink-0">
              <span className="text-white font-bold text-xs">AI</span>
            </div>
            <span className="font-semibold text-lg tracking-tight text-[var(--color-text-1)] hidden sm:inline">
              {title}
            </span>
          </div>

          <Breadcrumb
            items={getBreadcrumbItems()}
            className="text-sm !ml-6 hidden md:flex"
          />
        </div>

        <div className="flex items-center gap-2 pr-6">
          <Dropdown
            trigger={['hover', 'click']}
            placement="bottomRight"
            menu={{
              items: userMenuItems,
              onClick: handleUserMenuClick,
            }}
          >
            <button
              type="button"
              className="flex items-center gap-2 rounded-md px-2 py-1 transition-colors hover:bg-[var(--color-bg-hover)]"
              aria-label="用户菜单"
            >
              <Avatar
                size={28}
                src={user?.avatarUrl || undefined}
                className={user?.avatarUrl ? undefined : '!bg-[var(--color-primary)]'}
              >
                {!user?.avatarUrl ? (
                  <span className="text-white text-xs font-semibold flex items-center justify-center">
                    {userName.charAt(0).toUpperCase()}
                  </span>
                ) : null}
              </Avatar>
              <span className="max-w-[120px] truncate text-base font-medium text-[var(--color-text-1)]">
                {userName}
              </span>
            </button>
          </Dropdown>
        </div>
      </Header>

      <Layout className="flex-1 overflow-hidden">
        {/* Sider — desktop only */}
        <Sider
          width={200}
          collapsedWidth={0}
          trigger={null}
          className="dashboard-sider hidden lg:block"
          style={{
            display: undefined,
            flexDirection: 'column',
            overflow: 'hidden',
            position: 'sticky',
            top: 56,
            left: 0,
          }}
        >
          <div className="sider-menu-scroll">
            {siderMenu}
          </div>
        </Sider>

        {/* Main content */}
        <Content className="dashboard-content flex-1 overflow-auto">
          <div className="p-4 h-full">
            {children}
          </div>
        </Content>
      </Layout>

      <Modal
        open={profileModalOpen}
        onCancel={() => setProfileModalOpen(false)}
        footer={null}
        width={720}
        centered
        destroyOnHidden
        title={null}
        styles={{
          body: {
            padding: 24,
            height: 540,
            overflow: 'hidden',
          },
        }}
      >
        <ProfileContent />
      </Modal>
    </Layout>
  )
}
