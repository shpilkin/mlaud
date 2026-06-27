"""Конфигурация worker'а: пути и параметры."""

import os
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_AUDIO_EXTS = (".m4a", ".mp3", ".wav", ".aac", ".aiff", ".caf")


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

    def __post_init__(self):
        self.inbox = Path(self.inbox)
        self.output = Path(self.output)
        self.processed = Path(self.processed)
        self.failed = Path(self.failed)
        self.service = Path(self.service)

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
        )

    def ensure_dirs(self) -> None:
        for p in (self.output, self.processed, self.failed, self.service):
            p.mkdir(parents=True, exist_ok=True)

    @property
    def lock_path(self) -> Path:
        return self.service / "worker.lock"
