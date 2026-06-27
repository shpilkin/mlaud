"""Диаризация (кто говорит когда) через pyannote.audio 3.1.

Запускается опциональным слоем поверх ASR: интервалы спикеров накладываются на
тайм-коды сегментов GigaAM по максимальному перекрытию. Аудио подаётся уже
декодированным (наш ffmpeg-free load_audio), pyannote не трогает файл напрямую.
"""

from typing import Optional

from .audio import TARGET_SR, load_audio


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    """Длительность пересечения двух интервалов (0, если не пересекаются)."""
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def relabel(turns: list[dict], label_fmt: str = "Спикер {n}") -> dict:
    """Сырые метки pyannote (SPEAKER_00…) → человекочитаемые по порядку появления."""
    mapping: dict = {}
    for t in sorted(turns, key=lambda x: x["start"]):
        spk = t["speaker"]
        if spk not in mapping:
            mapping[spk] = label_fmt.format(n=len(mapping) + 1)
    return mapping


def assign_speakers(segments: list[dict], turns: list[dict],
                    label_fmt: str = "Спикер {n}") -> list[dict]:
    """Проставить каждому ASR-сегменту спикера по максимальному перекрытию с turns.

    Чистая функция (без pyannote) — тестируется отдельно. Сегменты не мутируются.
    """
    mapping = relabel(turns, label_fmt)
    result = []
    for seg in segments:
        best_label = None
        best_overlap = 0.0
        for t in turns:
            ov = _overlap(seg["start"], seg["end"], t["start"], t["end"])
            if ov > best_overlap:
                best_overlap = ov
                best_label = t["speaker"]
        new_seg = dict(seg)
        if best_label is not None:
            new_seg["speaker"] = mapping[best_label]
        result.append(new_seg)
    return result


def _best_speaker(start: float, end: float, turns: list[dict]):
    """Спикер с максимальным перекрытием интервала [start,end] или None."""
    best, best_ov = None, 0.0
    for t in turns:
        ov = _overlap(start, end, t["start"], t["end"])
        if ov > best_ov:
            best_ov, best = ov, t["speaker"]
    return best


def group_words_by_speaker(words: list[dict], turns: list[dict],
                           label_fmt: str = "Спикер {n}") -> list[dict]:
    """Разметить слова спикерами и склеить подряд идущие слова одного спикера в реплики.

    Это точная диаризация: границы реплик проходят по сменам спикера внутри речи,
    а не по 20-сек чанкам ASR. Возвращает сегменты [{'start','end','text','speaker'?}].
    """
    mapping = relabel(turns, label_fmt)
    segments: list[dict] = []
    last_raw = object()  # sentinel, не равен ни одному спикеру и None
    for w in words:
        raw = _best_speaker(w["start"], w["end"], turns)
        if segments and raw == last_raw:
            segments[-1]["text"] += " " + w["text"]
            segments[-1]["end"] = w["end"]
        else:
            seg = {"start": w["start"], "end": w["end"], "text": w["text"]}
            if raw is not None:
                seg["speaker"] = mapping[raw]
            segments.append(seg)
            last_raw = raw
    return segments


class Diarizer:
    """Ленивая загрузка pyannote-пайплайна; грузится при первом diarize()."""

    PIPELINE = "pyannote/speaker-diarization-3.1"

    def __init__(self, hf_token: Optional[str] = None, device: Optional[str] = None):
        self.hf_token = hf_token
        self.device = device  # None → mps (Apple Silicon, быстро); 'cpu' как запасной
        self._pipeline = None

    def _ensure_loaded(self) -> None:
        if self._pipeline is not None:
            return
        import inspect

        import torch
        from pyannote.audio import Pipeline

        # 3.x: use_auth_token=, 4.x: token= — выбираем по сигнатуре.
        params = inspect.signature(Pipeline.from_pretrained).parameters
        auth_kw = "token" if "token" in params else "use_auth_token"
        pipeline = Pipeline.from_pretrained(self.PIPELINE, **{auth_kw: self.hf_token})
        if pipeline is None:
            raise RuntimeError(
                "pyannote вернул None: не приняты условия модели или неверный HF-токен"
            )
        dev = self.device or "mps"
        pipeline.to(torch.device(dev))
        self._pipeline = pipeline

    def diarize(self, path: str, num_speakers: Optional[int] = None) -> list[dict]:
        """Вернуть интервалы спикеров: [{'start', 'end', 'speaker'}], speaker = SPEAKER_NN."""
        self._ensure_loaded()
        import torch

        wav = load_audio(path)  # float32 mono @16k
        waveform = torch.from_numpy(wav).unsqueeze(0)  # (1, samples)
        annotation = self._pipeline(
            {"waveform": waveform, "sample_rate": TARGET_SR},
            num_speakers=num_speakers,
        )
        turns = []
        for segment, _, speaker in annotation.itertracks(yield_label=True):
            turns.append(
                {"start": float(segment.start),
                 "end": float(segment.end),
                 "speaker": str(speaker)}
            )
        return turns
