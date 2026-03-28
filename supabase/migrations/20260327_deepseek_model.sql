-- 将 agents 表默认模型从 qwen2.5:7b 切换为 deepseek-chat
ALTER TABLE public.agents ALTER COLUMN model_name SET DEFAULT 'deepseek-chat';

UPDATE public.agents SET model_name = 'deepseek-chat' WHERE model_name = 'qwen2.5:7b';
