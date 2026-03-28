-- =====================================================
-- 统一迁移：初始化数据库
-- 合并自: 01_base, 02_profiles, 03_agents, 04_storage
-- 日期: 2026-03-14
-- =====================================================

-- ===========================================
-- 01_base: 基础设施
-- ===========================================

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

COMMENT ON FUNCTION public.update_updated_at_column()
    IS '自动更新 updated_at 字段的触发器函数';

-- ===========================================
-- 02_profiles: 用户资料
-- ===========================================

-- 枚举类型
DO $$ BEGIN
    CREATE TYPE public.user_role AS ENUM ('student', 'teacher', 'admin');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE public.account_status AS ENUM ('active', 'suspended');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 表
CREATE TABLE IF NOT EXISTS public.profiles (
    id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email         TEXT NOT NULL,
    role          public.user_role NOT NULL DEFAULT 'student',
    display_name  TEXT,
    avatar_url    TEXT,
    phone         TEXT,
    last_sign_in_at TIMESTAMPTZ,
    account_status  public.account_status NOT NULL DEFAULT 'active',
    status_reason   TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.profiles IS '用户资料表，记录角色与基础信息';

CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_email_unique ON public.profiles (lower(email));
CREATE INDEX IF NOT EXISTS idx_profiles_role ON public.profiles (role);
CREATE INDEX IF NOT EXISTS idx_profiles_account_status ON public.profiles (account_status);

GRANT SELECT, INSERT, UPDATE ON TABLE public.profiles TO authenticated;

-- 用户 RPC 函数

CREATE OR REPLACE FUNCTION public.current_profile()
RETURNS SETOF public.profiles
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
    SELECT * FROM public.profiles WHERE id = auth.uid();
$$;
COMMENT ON FUNCTION public.current_profile() IS '获取当前登录用户的完整 profile 信息';
GRANT EXECUTE ON FUNCTION public.current_profile() TO authenticated;

CREATE OR REPLACE FUNCTION public.ensure_current_profile(
    p_role TEXT DEFAULT 'student',
    p_display_name TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL
)
RETURNS public.profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
    v_email TEXT;
    v_role public.user_role;
    v_profile public.profiles;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    IF lower(COALESCE(p_role, 'student')) IN ('student', 'teacher') THEN
        v_role := lower(p_role)::public.user_role;
    ELSE
        v_role := 'student';
    END IF;

    SELECT COALESCE(NULLIF(BTRIM(p_email), ''), u.email, '')
    INTO v_email
    FROM auth.users AS u
    WHERE u.id = v_user_id;

    INSERT INTO public.profiles (id, email, role, display_name, last_sign_in_at)
    VALUES (v_user_id, COALESCE(v_email, ''), v_role, NULLIF(BTRIM(p_display_name), ''), now())
    ON CONFLICT (id) DO UPDATE
    SET
        email = EXCLUDED.email,
        role = CASE
            WHEN public.profiles.role = 'admin' THEN 'admin'::public.user_role
            ELSE EXCLUDED.role
        END,
        display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
        last_sign_in_at = now(),
        updated_at = now()
    RETURNING * INTO v_profile;

    RETURN v_profile;
END;
$$;
COMMENT ON FUNCTION public.ensure_current_profile(TEXT, TEXT, TEXT) IS '确保当前用户 profile 存在并同步 role/display_name/email';
GRANT EXECUTE ON FUNCTION public.ensure_current_profile(TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_profile_info(
    p_display_name TEXT,
    p_phone TEXT DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_display_name TEXT;
    v_phone TEXT;
BEGIN
    v_display_name := NULLIF(BTRIM(p_display_name), '');
    IF v_display_name IS NULL THEN RAISE EXCEPTION 'display_name 不能为空'; END IF;

    v_phone := NULLIF(BTRIM(p_phone), '');
    IF v_phone IS NOT NULL AND v_phone !~ '^[0-9+\-\s()]{6,20}$' THEN
        RAISE EXCEPTION 'phone 格式不正确';
    END IF;

    UPDATE public.profiles
    SET display_name = v_display_name, phone = v_phone, updated_at = now()
    WHERE id = auth.uid();

    RETURN FOUND;
END;
$$;
COMMENT ON FUNCTION public.update_profile_info(TEXT, TEXT) IS '更新当前登录用户 display_name/phone';
GRANT EXECUTE ON FUNCTION public.update_profile_info(TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_avatar_url(p_avatar_url TEXT)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    UPDATE public.profiles
    SET avatar_url = NULLIF(BTRIM(p_avatar_url), ''), updated_at = now()
    WHERE id = auth.uid();
    RETURN FOUND;
END;
$$;
COMMENT ON FUNCTION public.update_avatar_url(TEXT) IS '更新当前登录用户的 avatar_url';
GRANT EXECUTE ON FUNCTION public.update_avatar_url(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.verify_user_password(p_password TEXT)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = extensions, public, auth
AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN RAISE EXCEPTION '用户未登录'; END IF;

    RETURN EXISTS (
        SELECT 1 FROM auth.users
        WHERE id = v_user_id
          AND encrypted_password = crypt(p_password::TEXT, encrypted_password)
    );
END;
$$;
COMMENT ON FUNCTION public.verify_user_password(TEXT) IS '验证当前登录用户密码是否正确';
GRANT EXECUTE ON FUNCTION public.verify_user_password(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.is_current_user_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'admin' AND account_status = 'active'
    );
$$;
COMMENT ON FUNCTION public.is_current_user_admin() IS '判断当前登录用户是否为 active admin';
GRANT EXECUTE ON FUNCTION public.is_current_user_admin() TO authenticated;

-- 管理员 RPC 函数

CREATE OR REPLACE FUNCTION public.admin_list_users(
    p_keyword TEXT DEFAULT NULL,
    p_role TEXT DEFAULT NULL,
    p_status TEXT DEFAULT NULL,
    p_page integer DEFAULT 1,
    p_page_size integer DEFAULT 20,
    p_last_login_start timestamptz DEFAULT NULL,
    p_last_login_end timestamptz DEFAULT NULL
)
RETURNS TABLE (
    id uuid, email text, role public.user_role, display_name text,
    avatar_url text, phone text, last_sign_in_at timestamptz,
    created_at timestamptz, updated_at timestamptz,
    account_status public.account_status, status_reason text, total_count bigint
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_keyword text; v_role text; v_status text;
    v_page integer; v_page_size integer;
BEGIN
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可访问'; END IF;

    v_keyword := NULLIF(BTRIM(p_keyword), '');
    v_role := lower(COALESCE(NULLIF(BTRIM(p_role), ''), ''));
    v_status := lower(COALESCE(NULLIF(BTRIM(p_status), ''), ''));

    IF v_role <> '' AND v_role NOT IN ('student', 'teacher', 'admin') THEN RAISE EXCEPTION 'role 非法'; END IF;
    IF v_status <> '' AND v_status NOT IN ('active', 'suspended') THEN RAISE EXCEPTION 'status 非法'; END IF;

    v_page := GREATEST(COALESCE(p_page, 1), 1);
    v_page_size := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);

    RETURN QUERY
    WITH filtered AS (
        SELECT p.*
        FROM public.profiles p
        WHERE (v_keyword IS NULL OR (
                p.email ILIKE '%' || v_keyword || '%'
                OR COALESCE(p.display_name, '') ILIKE '%' || v_keyword || '%'
                OR COALESCE(p.phone, '') ILIKE '%' || v_keyword || '%'))
          AND (v_role = '' OR p.role::text = v_role)
          AND (v_status = '' OR p.account_status::text = v_status)
          AND (p_last_login_start IS NULL OR p.last_sign_in_at >= p_last_login_start)
          AND (p_last_login_end IS NULL OR p.last_sign_in_at <= p_last_login_end)
    ),
    counted AS (SELECT COUNT(*)::bigint AS cnt FROM filtered),
    paged AS (
        SELECT * FROM filtered
        ORDER BY updated_at DESC, created_at DESC
        LIMIT v_page_size OFFSET (v_page - 1) * v_page_size
    )
    SELECT paged.id, paged.email, paged.role, paged.display_name,
           paged.avatar_url, paged.phone, paged.last_sign_in_at,
           paged.created_at, paged.updated_at, paged.account_status,
           paged.status_reason, counted.cnt
    FROM paged CROSS JOIN counted;
END;
$$;
COMMENT ON FUNCTION public.admin_list_users(TEXT, TEXT, TEXT, integer, integer, timestamptz, timestamptz)
    IS '管理员分页查询用户列表，返回 total_count';
GRANT EXECUTE ON FUNCTION public.admin_list_users(TEXT, TEXT, TEXT, integer, integer, timestamptz, timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_update_user_basic(
    p_user_id uuid,
    p_display_name TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL,
    p_role TEXT DEFAULT NULL,
    p_avatar_url TEXT DEFAULT NULL
)
RETURNS public.profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_current_user_id uuid; v_new_role public.user_role;
    v_phone text; v_display_name text;
    v_target public.profiles; v_admin_count bigint; v_updated public.profiles;
BEGIN
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可操作'; END IF;
    IF p_user_id IS NULL THEN RAISE EXCEPTION 'user_id 不能为空'; END IF;

    v_current_user_id := auth.uid();
    SELECT * INTO v_target FROM public.profiles WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION '用户不存在'; END IF;

    v_new_role := COALESCE(NULLIF(lower(BTRIM(p_role)), '')::public.user_role, v_target.role);

    IF v_current_user_id = p_user_id AND v_new_role <> v_target.role THEN
        RAISE EXCEPTION '不能修改自己的角色';
    END IF;

    IF v_target.role = 'admin' AND v_new_role <> 'admin' THEN
        SELECT COUNT(*) INTO v_admin_count FROM public.profiles WHERE role = 'admin' AND account_status = 'active';
        IF v_admin_count <= 1 THEN RAISE EXCEPTION '系统至少保留一个 active admin'; END IF;
    END IF;

    IF p_display_name IS NOT NULL THEN
        v_display_name := NULLIF(BTRIM(p_display_name), '');
        IF v_display_name IS NULL THEN RAISE EXCEPTION 'display_name 不能为空'; END IF;
        IF char_length(v_display_name) > 50 THEN RAISE EXCEPTION 'display_name 长度不能超过 50'; END IF;
    ELSE v_display_name := v_target.display_name;
    END IF;

    IF p_phone IS NOT NULL THEN
        v_phone := NULLIF(BTRIM(p_phone), '');
        IF v_phone IS NOT NULL AND v_phone !~ '^[0-9+\-\s()]{6,20}$' THEN RAISE EXCEPTION 'phone 格式不正确'; END IF;
    ELSE v_phone := v_target.phone;
    END IF;

    UPDATE public.profiles
    SET display_name = v_display_name, phone = v_phone, role = v_new_role,
        avatar_url = CASE WHEN p_avatar_url IS NULL THEN avatar_url ELSE NULLIF(BTRIM(p_avatar_url), '') END,
        updated_at = now()
    WHERE id = p_user_id RETURNING * INTO v_updated;

    RETURN v_updated;
END;
$$;
COMMENT ON FUNCTION public.admin_update_user_basic(uuid, TEXT, TEXT, TEXT, TEXT)
    IS '管理员更新用户基础信息（显示名/手机号/角色/头像）';
GRANT EXECUTE ON FUNCTION public.admin_update_user_basic(uuid, TEXT, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_user_status(
    p_user_id uuid,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS public.profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_current_user_id uuid; v_status public.account_status;
    v_reason text; v_target public.profiles;
    v_admin_count bigint; v_updated public.profiles;
BEGIN
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可操作'; END IF;
    IF p_user_id IS NULL THEN RAISE EXCEPTION 'user_id 不能为空'; END IF;

    v_current_user_id := auth.uid();

    IF lower(BTRIM(p_status)) NOT IN ('active', 'suspended') THEN RAISE EXCEPTION 'status 非法'; END IF;
    v_status := lower(BTRIM(p_status))::public.account_status;

    IF v_current_user_id = p_user_id AND v_status = 'suspended' THEN RAISE EXCEPTION '不能停用自己'; END IF;

    SELECT * INTO v_target FROM public.profiles WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION '用户不存在'; END IF;

    IF v_target.role = 'admin' AND v_status = 'suspended' THEN
        SELECT COUNT(*) INTO v_admin_count FROM public.profiles WHERE role = 'admin' AND account_status = 'active';
        IF v_admin_count <= 1 THEN RAISE EXCEPTION '系统至少保留一个 active admin'; END IF;
    END IF;

    v_reason := NULLIF(BTRIM(p_reason), '');
    IF v_status = 'suspended' AND v_reason IS NULL THEN RAISE EXCEPTION '停用时必须填写原因'; END IF;

    UPDATE public.profiles
    SET account_status = v_status,
        status_reason = CASE WHEN v_status = 'active' THEN NULL ELSE v_reason END,
        updated_at = now()
    WHERE id = p_user_id RETURNING * INTO v_updated;

    RETURN v_updated;
END;
$$;
COMMENT ON FUNCTION public.admin_set_user_status(uuid, TEXT, TEXT)
    IS '管理员更新用户状态（active/suspended）';
GRANT EXECUTE ON FUNCTION public.admin_set_user_status(uuid, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_create_user(
    p_email TEXT,
    p_password TEXT,
    p_role TEXT DEFAULT 'student',
    p_display_name TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL
)
RETURNS TABLE (user_id uuid, email text, role text, display_name text, phone text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, extensions
AS $$
DECLARE
    v_email text; v_password text; v_role public.user_role;
    v_display_name text; v_phone text;
    v_user_id uuid; v_instance_id uuid;
BEGIN
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可操作'; END IF;

    v_email := lower(COALESCE(NULLIF(BTRIM(p_email), ''), ''));
    IF v_email = '' OR position('@' in v_email) <= 1 THEN RAISE EXCEPTION '邮箱格式不正确'; END IF;

    v_password := COALESCE(p_password, '');
    IF char_length(v_password) < 8 THEN RAISE EXCEPTION '密码至少 8 位'; END IF;

    IF lower(COALESCE(NULLIF(BTRIM(p_role), ''), 'student')) NOT IN ('student', 'teacher', 'admin') THEN
        RAISE EXCEPTION 'role 非法';
    END IF;
    v_role := lower(COALESCE(NULLIF(BTRIM(p_role), ''), 'student'))::public.user_role;

    v_display_name := NULLIF(BTRIM(p_display_name), '');
    IF v_display_name IS NOT NULL AND char_length(v_display_name) > 50 THEN
        RAISE EXCEPTION 'display_name 长度不能超过 50';
    END IF;

    v_phone := NULLIF(BTRIM(p_phone), '');
    IF v_phone IS NOT NULL AND v_phone !~ '^[0-9+\-\s()]{6,20}$' THEN RAISE EXCEPTION 'phone 格式不正确'; END IF;

    IF EXISTS (SELECT 1 FROM auth.users u WHERE lower(COALESCE(u.email, '')) = v_email) THEN
        RAISE EXCEPTION '该邮箱已注册';
    END IF;

    SELECT id INTO v_instance_id FROM auth.instances LIMIT 1;
    IF v_instance_id IS NULL THEN v_instance_id := '00000000-0000-0000-0000-000000000000'::uuid; END IF;

    v_user_id := gen_random_uuid();

    INSERT INTO auth.users (
        id, instance_id, aud, role, email,
        encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change
    ) VALUES (
        v_user_id, v_instance_id, 'authenticated', 'authenticated', v_email,
        crypt(v_password, gen_salt('bf')), now(),
        jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
        jsonb_strip_nulls(jsonb_build_object('role', v_role::text, 'display_name', v_display_name, 'phone', v_phone)),
        now(), now(), '', '', '', ''
    );

    INSERT INTO public.profiles (id, email, role, display_name, phone, account_status, status_reason, last_sign_in_at)
    VALUES (v_user_id, v_email, v_role, COALESCE(v_display_name, split_part(v_email, '@', 1)), v_phone, 'active', NULL, NULL)
    ON CONFLICT (id) DO UPDATE
    SET email = EXCLUDED.email, role = EXCLUDED.role,
        display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
        phone = EXCLUDED.phone, account_status = 'active', status_reason = NULL, updated_at = now();

    RETURN QUERY SELECT v_user_id, v_email, v_role::text, v_display_name, v_phone;
END;
$$;
COMMENT ON FUNCTION public.admin_create_user(TEXT, TEXT, TEXT, TEXT, TEXT)
    IS '管理员创建用户（支持 student/teacher/admin），并同步 profile';
GRANT EXECUTE ON FUNCTION public.admin_create_user(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_reset_user_password(p_user_id uuid, p_new_password TEXT)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, extensions
AS $$
BEGIN
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可操作'; END IF;
    IF p_user_id IS NULL THEN RAISE EXCEPTION 'user_id 不能为空'; END IF;
    IF char_length(COALESCE(p_new_password, '')) < 8 THEN RAISE EXCEPTION '密码至少 8 位'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN RAISE EXCEPTION '用户不存在'; END IF;

    UPDATE auth.users SET encrypted_password = crypt(p_new_password, gen_salt('bf')), updated_at = now()
    WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION '用户不存在'; END IF;

    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION public.admin_reset_user_password(uuid, TEXT) IS '管理员重置指定用户密码';
GRANT EXECUTE ON FUNCTION public.admin_reset_user_password(uuid, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_delete_user(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth
AS $$
DECLARE v_target public.profiles; v_admin_count bigint;
BEGIN
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可操作'; END IF;
    IF p_user_id IS NULL THEN RAISE EXCEPTION 'user_id 不能为空'; END IF;
    IF auth.uid() = p_user_id THEN RAISE EXCEPTION '不能删除自己'; END IF;

    SELECT * INTO v_target FROM public.profiles WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION '用户不存在'; END IF;

    IF v_target.role = 'admin' THEN
        SELECT COUNT(*) INTO v_admin_count FROM public.profiles WHERE role = 'admin' AND account_status = 'active';
        IF v_admin_count <= 1 THEN RAISE EXCEPTION '系统至少保留一个 active admin'; END IF;
    END IF;

    DELETE FROM auth.users WHERE id = p_user_id;
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION public.admin_delete_user(uuid) IS '管理员删除用户（同时删除 auth.users 和 profiles）';
GRANT EXECUTE ON FUNCTION public.admin_delete_user(uuid) TO authenticated;

-- 触发器

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE OR REPLACE FUNCTION public.sync_auth_user_to_profile()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    metadata JSONB;
    requested_role TEXT;
    normalized_role public.user_role;
    existing_role public.user_role;
    display_name_value TEXT;
    avatar_url_value TEXT;
    phone_value TEXT;
BEGIN
    metadata := COALESCE(NEW.raw_user_meta_data, '{}'::JSONB);
    requested_role := lower(COALESCE(metadata ->> 'role', ''));

    SELECT p.role INTO existing_role FROM public.profiles AS p WHERE p.id = NEW.id;

    IF existing_role IS NOT NULL THEN
        normalized_role := existing_role;
    ELSIF requested_role IN ('student', 'teacher') THEN
        normalized_role := requested_role::public.user_role;
    ELSE
        normalized_role := 'student';
    END IF;

    display_name_value := NULLIF(BTRIM(COALESCE(metadata ->> 'display_name', metadata ->> 'full_name')), '');
    avatar_url_value := NULLIF(BTRIM(metadata ->> 'avatar_url'), '');
    phone_value := NULLIF(BTRIM(metadata ->> 'phone'), '');

    INSERT INTO public.profiles (id, email, role, display_name, avatar_url, phone, last_sign_in_at)
    VALUES (
        NEW.id, COALESCE(NEW.email, ''), normalized_role,
        COALESCE(display_name_value, split_part(COALESCE(NEW.email, ''), '@', 1)),
        avatar_url_value, phone_value, NEW.last_sign_in_at
    )
    ON CONFLICT (id) DO UPDATE
    SET
        email = EXCLUDED.email,
        role = CASE WHEN public.profiles.role IS NOT NULL THEN public.profiles.role ELSE normalized_role END,
        display_name = COALESCE(display_name_value, public.profiles.display_name),
        avatar_url = COALESCE(avatar_url_value, public.profiles.avatar_url),
        phone = COALESCE(phone_value, public.profiles.phone),
        last_sign_in_at = COALESCE(NEW.last_sign_in_at, public.profiles.last_sign_in_at),
        updated_at = now();

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auth_users_profile_insert ON auth.users;
CREATE TRIGGER trg_auth_users_profile_insert
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.sync_auth_user_to_profile();

DROP TRIGGER IF EXISTS trg_auth_users_profile_update ON auth.users;
CREATE TRIGGER trg_auth_users_profile_update
    AFTER UPDATE OF email, raw_user_meta_data, last_sign_in_at ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.sync_auth_user_to_profile();

-- 回填历史用户
INSERT INTO public.profiles (id, email, role, display_name, last_sign_in_at)
SELECT
    u.id, COALESCE(u.email, ''),
    CASE
        WHEN lower(COALESCE(u.raw_user_meta_data ->> 'role', '')) IN ('student', 'teacher', 'admin')
            THEN lower(u.raw_user_meta_data ->> 'role')::public.user_role
        ELSE 'student'::public.user_role
    END,
    NULLIF(BTRIM(COALESCE(
        u.raw_user_meta_data ->> 'display_name',
        u.raw_user_meta_data ->> 'full_name',
        split_part(COALESCE(u.email, ''), '@', 1)
    )), ''),
    u.last_sign_in_at
FROM auth.users AS u
ON CONFLICT (id) DO NOTHING;

-- RLS 策略
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile"
    ON public.profiles FOR SELECT USING (auth.uid() = id);

DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
CREATE POLICY "Admins can view all profiles"
    ON public.profiles FOR SELECT USING (public.is_current_user_admin());

DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
CREATE POLICY "Users can insert own profile"
    ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id AND role IN ('student', 'teacher'));

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id AND role IN ('student', 'teacher'));

-- ===========================================
-- 03_agents: AI 智能体配置
-- ===========================================

DO $$ BEGIN
    CREATE TYPE public.agent_status AS ENUM ('enabled', 'disabled');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.agents (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    target_role TEXT NOT NULL DEFAULT 'all' CHECK (target_role IN ('all', 'student', 'teacher')),
    status      public.agent_status NOT NULL DEFAULT 'enabled',
    description TEXT,
    avatar      TEXT,
    instructions TEXT,
    model_name  TEXT NOT NULL DEFAULT 'deepseek-chat',
    temperature NUMERIC(3,2) NOT NULL DEFAULT 0.7 CHECK (temperature >= 0 AND temperature <= 2),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.agents IS 'AI Agent 配置表，由 AgentManager 启动时读取';

CREATE INDEX IF NOT EXISTS idx_agents_status ON public.agents (status);
CREATE INDEX IF NOT EXISTS idx_agents_target_role ON public.agents (target_role);

DROP TRIGGER IF EXISTS set_agents_updated_at ON public.agents;
CREATE TRIGGER set_agents_updated_at
    BEFORE UPDATE ON public.agents
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 种子数据
INSERT INTO public.agents (id, name, target_role, status, description, instructions, model_name, temperature)
VALUES (
    'a0000000-0000-0000-0000-000000000001',
    '教学助手', 'student', 'enabled',
    'AI 教学助手，帮助学生学习编程和计算机科学知识',
    '你是一个专业的 AI 教学助手。你的职责是：
1. 耐心解答学生的编程和计算机科学问题
2. 用通俗易懂的语言解释复杂概念
3. 提供代码示例来辅助说明
4. 鼓励学生思考，而不是直接给出完整答案
5. 如果学生的理解有误，温和地纠正

请用中文回答，除非学生用其他语言提问。回答要简洁有条理。',
    'deepseek-chat', 0.7
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.agents (id, name, target_role, status, description, instructions, model_name, temperature)
VALUES (
    'a0000000-0000-0000-0000-000000000002',
    '教师教学智能体', 'teacher', 'enabled',
    '面向教师端的教学设计与课堂支持助手',
    '你是教师端教学智能体。你的职责是：
1. 协助教师完成教学目标拆解与课时规划
2. 生成分层教学策略（基础/进阶/拔高）
3. 产出课堂活动、随堂测与作业建议
4. 根据学生表现给出差异化辅导建议
5. 输出应简洁、结构化、可直接执行

请始终使用中文回答，并优先给出可落地的教学建议。',
    'deepseek-chat', 0.7
) ON CONFLICT (id) DO NOTHING;

-- ===========================================
-- 04_storage: 头像存储
-- ===========================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('avatars', 'avatars', true, 2097152, ARRAY['image/jpeg', 'image/png', 'image/gif', 'image/webp'])
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "Users can upload own avatar" ON storage.objects;
CREATE POLICY "Users can upload own avatar"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "Users can update own avatar" ON storage.objects;
CREATE POLICY "Users can update own avatar"
    ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::text)
    WITH CHECK (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "Users can delete own avatar" ON storage.objects;
CREATE POLICY "Users can delete own avatar"
    ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "Anyone can view avatars" ON storage.objects;
CREATE POLICY "Anyone can view avatars"
    ON storage.objects FOR SELECT TO public
    USING (bucket_id = 'avatars');
