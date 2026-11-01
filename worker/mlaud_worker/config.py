"""Конфигурация worker'а: пути и параметры."""

import os
from dataclasses import dataclass, field
from pathlib import Path

# webm/mkv/ogg/opus CoreAudio не открывает — их декодирует ffmpeg (audio.py).
DEFAULT_AUDIO_EXTS = (".m4a", ".mp3", ".wav", ".aac", ".aiff", ".caf", ".flac",
                      ".mp4", ".webm", ".mkv", ".ogg", ".oga", ".opus")

ENV_PATH = Path(__file__).resolve().parent.parent / ".env"


def read_dotenv(path: Path = ENV_PATH) -> dict:
    """Пары ключ=значение из worker/.env (без зависимости python-dotenv): первое непустое."""
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip().strip('"').strip("'")
        if key and val and key not in values:
            values[key] = val
    return values


@dataclass
class Config:
    inbox: Path           # iCloud .../ASR/ASRInbox/AllRecords (транзит)
    output: Path          # локально ~/ASR/ASROutput/AllOutputs
    processed: Path       # локально ~/ASR/Processed/AllRecords
    failed: Path          # локально ~/ASR/Failed (карантин упавших файлов)
    service: Path         # локально ~/ASR/service (логи, lock)
    model_type: str = "rnnt"
    audio_exts: tuple = field(default_factory=lambda: DEFAULT_AUDIO_EXTS)
    # Диаризация (опционально, pyannote 3.1)
    diarize: bool = False
    hf_token: str = ""
    diarize_device: str = "mps"   # 'mps' на Apple Silicon ~22x быстрее CPU; 'cpu' как запасной
    num_speakers: int = 0         # 0 = автоопределение
    # Голос-ID (Фаза 3) — опция поверх диаризации: без diarize не включается.
    # Пороги и фильтр измерены, а не назначены (ADR-016).
    identify: bool = False
    voices_dir: Path = field(default_factory=lambda: Path.home() / "ASR/voices")  # не iCloud: биометрия
    identify_threshold: float = 0.75    # пресеты: строго 0.80 / баланс 0.75 / мягко 0.70
    identify_min_speech: float = 30.0   # c речи в кластере; короче — имени нет никогда (FR-8.9)
    # Папка обмена роутера (Niti). None = сдача артефактов выключена, конвейер работает
    # ровно как раньше. Путь задаётся снаружи: у роутера каталог данных переопределяется
    # переменной окружения, поэтому хардкодить его нельзя.
    router_inbox: Path | None = None
    # Папка Суфлёра: profile.md, templates/, briefs/, calls/ (feature-prompter.md §3.0); не iCloud.
    prompter_dir: Path = field(default_factory=lambda: Path.home() / "ASR/Prompter")

    def __post_init__(self):
        self.inbox = Path(self.inbox)
        self.output = Path(self.output)
        self.processed = Path(self.processed)
        self.failed = Path(self.failed)
        self.service = Path(self.service)
        self.voices_dir = Path(self.voices_dir)
        self.prompter_dir = Path(self.prompter_dir)
        if self.router_inbox is not None:
            self.router_inbox = Path(self.router_inbox)

    @classmethod
    def default(cls) -> "Config":
        home = Path.home()
        icloud = home / "Library/Mobile Documents/com~apple~CloudDocs"
        return cls(
            inbox=icloud / "ASR/ASRInbox/AllRecords",
            output=home / "ASR/ASROutput/AllOutputs",
            processed=home / "ASR/Processed/AllRecords",
            failed=home / "ASR/Failed",
            service=home / "ASR/service",
            # Штатное место каталога данных роутера. Сдача включается сама, когда роутер
            # установлен, и молча не происходит, когда его нет (см. pipeline._handoff) —
            # чтобы не плодить папку, которую никто не читает. Переопределяется
            # MLAUD_ROUTER_INBOX: у роутера каталог данных задаётся переменной окружения.
            router_inbox=home / "Library/Application Support/EmailReader/artifacts_inbox",
        )

    def ensure_dirs(self) -> None:
        for p in (self.output, self.processed, self.failed, self.service):
            p.mkdir(parents=True, exist_ok=True)

    @property
    def lock_path(self) -> Path:
        return self.service / "worker.lock"

    @property
    def asr_root(self) -> Path | None:
        """Общий корень архива (обычно ~/ASR): от него роутер считает пути к файлам.

        Считается из фактических путей, а не хардкодится, — переопределили каталоги,
        корень поехал вместе с ними. None, если общего корня нет (разные тома): тогда
        в артефакт уйдут абсолютные пути."""
        try:
            return Path(os.path.commonpath([str(self.output), str(self.processed)]))
        except ValueError:
            return None
