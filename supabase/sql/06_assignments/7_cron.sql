-- =====================================================
-- 模块 06_assignments：pg_cron 自动截止定时任务
-- =====================================================
-- 注意：需要在 Supabase 控制台启用 pg_cron 扩展
--   Database → Extensions → 搜索 pg_cron → Enable

-- 每分钟检查一次已到期的已发布作业，自动切换为 closed
SELECT cron.schedule(
    'auto-close-assignments',
    '* * * * *',
    $$
        UPDATE public.assignments
        SET status = 'closed', updated_at = now()
        WHERE status = 'published'
          AND deadline IS NOT NULL
          AND deadline <= now();
    $$
);
