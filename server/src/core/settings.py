from pydantic import BaseModel
from pydantic_settings import BaseSettings, SettingsConfigDict


class DeepSeekSettings(BaseModel):
    """DeepSeek 云端 LLM 配置"""

    api_key: str = ""
    base_url: str = "https://api.deepseek.com"
    default_model: str = "deepseek-chat"
    chat_model: str | None = None
    title_model: str | None = None

    @property
    def resolved_chat_model(self) -> str:
        """聊天主链路使用的模型（优先 chat_model）。"""
        return self.chat_model or self.default_model

    @property
    def resolved_title_model(self) -> str:
        """标题生成链路使用的模型（若未配置则回落到默认聊天模型）。"""
        return self.title_model or self.resolved_chat_model


class SupabaseSettings(BaseModel):
    """Supabase Cloud 配置"""

    url: str = ""
    anon_key: str = ""
    service_key: str = ""
    jwt_secret: str = ""


class OllamaSettings(BaseModel):
    """Ollama LLM 配置（AI 批改）"""

    base_url: str = "http://localhost:11434"
    model: str = "qwen2.5:7b"
    temperature: float = 0.3
    timeout_per_question: int = 60
    job_timeout: int = 300


class DatabaseSettings(BaseModel):
    """本地 SQLite 数据库配置（agno session 存储）"""

    path: str = "./data/agno.db"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_nested_delimiter="__",
    )

    debug: bool = False
    host: str = "0.0.0.0"
    port: int = 8100

    deepseek: DeepSeekSettings = DeepSeekSettings()
    supabase: SupabaseSettings = SupabaseSettings()
    database: DatabaseSettings = DatabaseSettings()
    ollama: OllamaSettings = OllamaSettings()


settings = Settings()
