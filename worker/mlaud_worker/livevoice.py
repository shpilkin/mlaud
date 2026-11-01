"""Живая пометка «Я / не я» для офлайн-звонка (этап 5, S4 → poc/spkid/RESULT-S4.md,
замер тракта → poc/livespk/RESULT.md).

Эмбеддится только речь: окно фразы вырезается по дорожкам говорящих
`segmentation-3.0` (powerset, 3 локальных спикера), метка — по доминирующей
дорожке; короче 1.5 с речи пометки нет. Причина: тракт MacBook-микрофона отдаёт
звук после гейта (48–65 % точных нулей, «Изоляция голоса»), и эмбеддинг сырого
окна измеряет гейт, а не голос — «разговорный» эталон из 0.13.5 оказался
отпечатком тишины и совпадал с любым пустым окном. Счёт — лучший косинус по
образцам персоны «Я»: режимы голоса одного человека (начитка и разговор)
различаются, средний центроид теряет оба. Порог — замер poc/livespk на чистой
речи; имена и «Гость A/B» вживую не ставятся (S4)."""

from pathlib import Path
from typing import Callable, Optional

import numpy as np

from . import spkid

THRESHOLD = 0.40
MIN_SPEECH_SEC = 1.5
SELF_NAME = "Я"
MODEL = "pyannote/wespeaker-voxceleb-resnet34-LM"
SEG_MODEL = "pyannote/segmentation-3.0"
SR = 16000


def _cosine(a: np.ndarray, b: np.ndarray) -> float:
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na == 0 or nb == 0:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


class LiveVoice:
    """Маркер фраз: образцы «Я» из базы, вырезка речи и эмбеддинг."""

    def __init__(self, embed: Callable[[np.ndarray], np.ndarray],
                 speech_tracks: Callable[[np.ndarray], list],
                 refs: list, threshold: float = THRESHOLD,
                 min_speech_sec: float = MIN_SPEECH_SEC):
        self.embed = embed
        self.speech_tracks = speech_tracks
        self.refs = [u for u in (spkid.normalize(r) for r in refs) if u is not None]
        self.threshold = threshold
        self.min_speech_sec = min_speech_sec

    def mark(self, samples: np.ndarray) -> Optional[dict]:
        """{"self", "score", "speech"} для доминирующей дорожки окна с ≥ min_speech_sec
        речи; меньше речи или нет образцов — None. Голосовые метки живьём в базу
        не пишутся (5.4) — это только событие."""
        if not self.refs:
            return None
        tracks = self.speech_tracks(samples)
        if not tracks:
            return None
        sec, speech = max(tracks, key=lambda t: t[0])   # доминирующая дорожка
        if sec < self.min_speech_sec:
            return None
        emb = spkid.normalize(self.embed(speech))
        if emb is None:
            return None
        score = max(_cosine(emb, ref) for ref in self.refs)
        return {"self": score >= self.threshold, "score": round(score, 2),
                "speech": round(sec, 1)}


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
    return LiveVoice(_cpu_embedder(), _cpu_speech_tracks(), refs)


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


def _cpu_speech_tracks() -> Callable[[np.ndarray], list]:
    """Речь каждой дорожки говорящего внутри окна: segmentation-3.0, powerset-классы
    (0 — тишина, 1–3 один спикер, 4–6 два). Куски ≤ 10 с, дорожки по кускам не
    сшиваются — для доминирующей дорожки окна этого достаточно. CPU, один раз
    на процесс. [(секунд речи, сэмплы речи)] по убыванию речи (poc/livespk/eval.py)."""
    import torch
    from pyannote.audio import Model

    seg = Model.from_pretrained(SEG_MODEL).eval()
    chunk = 10 * SR
    active = {0: {1, 4, 5}, 1: {2, 4, 6}, 2: {3, 5, 6}}   # powerset → дорожки

    def tracks(samples: np.ndarray) -> list:
        x = np.asarray(samples, dtype=np.float32).reshape(-1)
        out = []
        with torch.no_grad():
            for i in range(0, max(len(x), 1), chunk):
                piece = x[i:i + chunk]
                if piece.size < SR:                      # хвост короче секунды — добить тишиной
                    piece = np.pad(piece, (0, SR - piece.size))
                prob = torch.exp(seg(torch.from_numpy(piece.reshape(1, 1, -1)))[0]).numpy()
                step = piece.size / prob.shape[0]
                cls = prob.argmax(axis=1)
                for spk, classes in active.items():
                    idx = [j for j, c in enumerate(cls) if c in classes]
                    if not idx:
                        continue
                    parts = [piece[int(j * step):int((j + 1) * step)] for j in idx]
                    xs = np.concatenate(parts)
                    out.append((len(xs) / SR, xs))
        return sorted(out, key=lambda t: -t[0])

    return tracks
