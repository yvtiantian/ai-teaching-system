from src.core.settings import settings


def test_settings_exposes_required_sections_and_keys():
    assert hasattr(settings, "supabase")
    assert hasattr(settings, "deepseek")
    assert hasattr(settings, "database")

    assert hasattr(settings.supabase, "url")
    assert hasattr(settings.supabase, "anon_key")
    assert hasattr(settings.supabase, "service_key")
    assert hasattr(settings.supabase, "jwt_secret")

    assert hasattr(settings.deepseek, "api_key")
    assert hasattr(settings.deepseek, "default_model")
    assert hasattr(settings.deepseek, "base_url")

    assert hasattr(settings.database, "path")
