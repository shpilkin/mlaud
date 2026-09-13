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
    """Маркер фраз: держит образцы «Я» из базы голосов и функцию эмбеддинга."""

    def __init__(self, embed: Callable[[np.ndarray], np.ndarray], refs: list,
                 threshold: float = THRESHOLD, min_sec: float = MIN_SEC):
        self.embed = embed
        # Режимы голоса одного человека почти ортогональны (замер 2026-09-13:
        # «начитка вплотную» и разговорная речь — ~0.2 друг к другу), средний
        # центроид теряет оба — счёт ведётся по лучшему образцу.
        self.refs = [u for u in (spkid.normalize(r) for r in refs) if u is not None]
        self.threshold = threshold
        self.min_sec = min_sec

    def mark(self, samples: np.ndarray) -> Optional[dict]:
        """{"self": bool, "score": лучший косинус} для фразы ≥ min_sec; короче — None.
        Голосовые метки живьём в базу не пишутся (5.4) — это только событие."""
        if not self.refs or samples.size < int(self.min_sec * SR):
            return None
        emb = spkid.normalize(self.embed(samples))
        if emb is None:
            return None
        score = max(_cosine(emb, ref) for ref in self.refs)
        return {"self": score >= self.threshold, "score": round(score, 2)}


def self_refs(store) -> list:
    """Все образцы персоны «я»: точное «Я» старше регистра-двойника («я» с маленькой
    бывала заведена вручную до этапа 5). Персоны нет — пусто."""
    people = store.people()
    name = SELF_NAME if SELF_NAME in people else next(
        (n for n in people if n.lower() == SELF_NAME.lower()), None)
    if name is None:
        return []
    refs = []
    for sid in people[name].get("samples", []):
        path = store.samples_dir / f"{sid}.npy"
        if path.exists():
            refs.append(np.load(path))
    return refs


def load(voices_dir: Path) -> Optional[LiveVoice]:
    """Живой маркер из базы голосов: образцы персоны «Я»; персоны нет — None."""
    from .voices import VoiceStore

    refs = self_refs(VoiceStore(voices_dir))
    if not refs:
        return None
    return LiveVoice(_cpu_embedder(), refs)


def _cpu_embedder() -> Callable[[np.ndarray], np.ndarray]:
    """wespeaker на CPU; грузится один раз на процесс при первом голосовом канале."""
    import torch
    from pyannote.audio import Inference, Model

    model = Model.from_pretrained(MODEL)
    inference = Inference(model, window="whole", device=torch.device("cpu"))

    def embed(samples: np.ndarray) -> np.ndarray:
        # Inference.infer делает chunks.to(device) — на вход нужен тензор, numpy там падает.
        wave = torch.from_numpy(np.ascontiguousarray(samples.reshape(1, -1)))
        out = inference({"waveform": wave, "sample_rate": SR})
        return np.asarray(out).reshape(-1)

    return embed
