"""Живая пометка «Я / не я» для офлайн-звонка (этап 5, S4 → poc/spkid/RESULT-S4.md).

Эмбеддинг фразы — wespeaker (та же модель, что в диаризации), окно = вся фраза,
CPU: не делит ускоритель с MLX-распознавателем. Порог 0.60 снят на 127 чужих клипов:
71 % своих ≥ 2 с помечены «Я», ложных «Я» — ноль. Фразы короче 2 с сигнала не несут —
без пометки. Имена и «Гость A/B» вживую не ставятся (S4)."""

from pathlib import Path
from typing import Callable, Optional

import numpy as np

from . import spkid

THRESHOLD = 0.60
MIN_SEC = 2.0
SELF_NAME = "Я"
MODEL = "pyannote/wespeaker-voxceleb-resnet34-LM"
SR = 16000


def _cosine(a: np.ndarray, b: np.ndarray) -> float:
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na == 0 or nb == 0:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


class LiveVoice:
    """Маркер фраз: держит центроид «Я» из базы голосов и функцию эмбеддинга."""

    def __init__(self, embed: Callable[[np.ndarray], np.ndarray], centroid: np.ndarray,
                 threshold: float = THRESHOLD, min_sec: float = MIN_SEC):
        self.embed = embed
        self.centroid = spkid.normalize(centroid)
        self.threshold = threshold
        self.min_sec = min_sec

    def mark(self, samples: np.ndarray) -> Optional[dict]:
        """{"self": bool, "score": косинус} для фразы ≥ min_sec; короче — None.
        Голосовые метки живьём в базу не пишутся (5.4) — это только событие."""
        if self.centroid is None or samples.size < int(self.min_sec * SR):
            return None
        emb = spkid.normalize(self.embed(samples))
        if emb is None:
            return None
        score = _cosine(emb, self.centroid)
        return {"self": score >= self.threshold, "score": round(score, 2)}


def self_centroid(gallery: dict) -> Optional[np.ndarray]:
    """Центроид персоны «я» без учёта регистра: в базе бывает «я» с маленькой
    (заведена вручную до этапа 5); новые записи всегда канонические «Я»."""
    for name, vec in gallery.items():
        if name.lower() == SELF_NAME.lower():
            return vec
    return None


def load(voices_dir: Path) -> Optional[LiveVoice]:
    """Живой маркер из базы голосов: центроид персоны «Я»; персоны нет — None."""
    from .voices import VoiceStore

    centroid = self_centroid(VoiceStore(voices_dir).gallery())
    if centroid is None:
        return None
    return LiveVoice(_cpu_embedder(), centroid)


def _cpu_embedder() -> Callable[[np.ndarray], np.ndarray]:
    """wespeaker на CPU; грузится один раз на процесс при первом голосовом канале."""
    import torch
    from pyannote.audio import Inference, Model

    model = Model.from_pretrained(MODEL)
    inference = Inference(model, window="whole", device=torch.device("cpu"))

    def embed(samples: np.ndarray) -> np.ndarray:
        wave = samples.reshape(1, -1)
        out = np.asarray(inference({"waveform": wave, "sample_rate": SR}))
        return out.reshape(-1)

    return embed
