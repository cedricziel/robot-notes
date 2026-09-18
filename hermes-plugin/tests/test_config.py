import json

from robot_notes import config as config_module
from robot_notes.config import API_KEY_ENV_VAR, RobotNotesConfig


def test_load_reads_base_url_and_actor_from_hermes_home(tmp_path, monkeypatch):
    monkeypatch.delenv("ROBOT_NOTES_API_KEY", raising=False)
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com", "actor": "hermes-bot"}),
        encoding="utf-8",
    )

    config = RobotNotesConfig.load(str(tmp_path))

    assert config.base_url == "https://notes.example.com"
    assert config.actor == "hermes-bot"


def test_load_reads_api_key_from_env(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")

    config = RobotNotesConfig.load(str(tmp_path))

    assert config.api_key == "secret-key"


def test_load_reads_api_key_via_get_secret(tmp_path, monkeypatch):
    """The Hermes secret-scope contract: the API key must be resolved through
    get_secret (which honours the per-turn/profile scope under multiplexing), never
    read straight from os.environ. Proven by monkeypatching the compat function itself,
    matching how the threading contract is proven for spawn_context_thread."""
    calls = []

    def fake_get_secret(name, default=""):
        calls.append(name)
        return "secret-from-compat"

    monkeypatch.setattr(config_module, "get_secret", fake_get_secret)
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "should-not-be-read-directly")

    config = RobotNotesConfig.load(str(tmp_path))

    assert config.api_key == "secret-from-compat"
    assert calls == [API_KEY_ENV_VAR]


def test_get_secret_reads_env_var_directly(monkeypatch):
    """Outside a hermes-agent checkout, get_secret's fallback keeps today's plain
    os.environ behaviour (no profile scoping) -- exercised directly, not through
    RobotNotesConfig, since a real hermes-agent checkout on the test path would use
    its own get_secret_str instead and skip this fallback entirely."""
    monkeypatch.setenv(API_KEY_ENV_VAR, "secret-key")

    assert config_module.get_secret(API_KEY_ENV_VAR, "") == "secret-key"

    monkeypatch.delenv(API_KEY_ENV_VAR, raising=False)

    assert config_module.get_secret(API_KEY_ENV_VAR, "") == ""


def test_load_defaults_actor_when_unset(tmp_path, monkeypatch):
    monkeypatch.delenv("ROBOT_NOTES_API_KEY", raising=False)

    config = RobotNotesConfig.load(str(tmp_path))

    assert config.actor == "hermes"


def test_load_strips_trailing_slash_from_base_url(tmp_path, monkeypatch):
    monkeypatch.delenv("ROBOT_NOTES_API_KEY", raising=False)
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com/"}), encoding="utf-8"
    )

    config = RobotNotesConfig.load(str(tmp_path))

    assert config.base_url == "https://notes.example.com"


def test_missing_reason_names_base_url_when_absent(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")

    config = RobotNotesConfig.load(str(tmp_path))

    assert config.missing_reason is not None
    assert "base_url" in config.missing_reason


def test_missing_reason_names_api_key_when_absent(tmp_path, monkeypatch):
    monkeypatch.delenv("ROBOT_NOTES_API_KEY", raising=False)
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com"}), encoding="utf-8"
    )

    config = RobotNotesConfig.load(str(tmp_path))

    assert config.missing_reason is not None
    assert "ROBOT_NOTES_API_KEY" in config.missing_reason


def test_is_complete_true_once_both_are_set(tmp_path, monkeypatch):
    monkeypatch.setenv("ROBOT_NOTES_API_KEY", "secret-key")
    (tmp_path / "robot_notes.json").write_text(
        json.dumps({"base_url": "https://notes.example.com"}), encoding="utf-8"
    )

    config = RobotNotesConfig.load(str(tmp_path))

    assert config.is_complete is True


def test_save_writes_base_url_and_actor_but_not_api_key(tmp_path):
    config = RobotNotesConfig(base_url="https://notes.example.com", actor="hermes-bot", api_key="secret-key")

    config.save(str(tmp_path))

    saved = json.loads((tmp_path / "robot_notes.json").read_text(encoding="utf-8"))
    assert saved == {"base_url": "https://notes.example.com", "actor": "hermes-bot"}
    assert "api_key" not in saved
    assert "secret-key" not in (tmp_path / "robot_notes.json").read_text(encoding="utf-8")
