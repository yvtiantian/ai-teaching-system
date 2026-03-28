-- =====================================================
-- 模块 03_agents：AI 智能体配置表
-- =====================================================

CREATE TABLE IF NOT EXISTS public.agents (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    target_role TEXT NOT NULL DEFAULT 'all'
        CHECK (target_role IN ('all', 'student', 'teacher')),
    status      public.agent_status NOT NULL DEFAULT 'enabled',
    description TEXT,
    avatar      TEXT,
    instructions TEXT,
    model_name  TEXT NOT NULL DEFAULT 'deepseek-chat',
    temperature NUMERIC(3,2) NOT NULL DEFAULT 0.7
        CHECK (temperature >= 0 AND temperature <= 2),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.agents IS 'AI Agent 配置表，由 AgentManager 启动时读取';

CREATE INDEX IF NOT EXISTS idx_agents_status ON public.agents (status);
CREATE INDEX IF NOT EXISTS idx_agents_target_role ON public.agents (target_role);
