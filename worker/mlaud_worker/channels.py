"""Записи звонка Суфлёра: сайдкар каналов и транскрипция по дорожкам.

Приложение пишет стерео `.m4a` (L = «Я», R = собеседник) и рядом `<call_id>.channels.json`
(docs/feature-prompter.md §4.3, ADR-026). Для такого файла диаризация не нужна: кто говорит —
известно по каналу. Каждая дорожка транскрибируется отдельно, реплики сливаются по времени.
"""

import json
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import numpy as np
import soundfile as sf

from .audio import AudioDecodeError

SIDECAR_SUFFIX = ".channels.json"
CALL_ID_FORMAT = "%Y-%m-%d_%H-%M-%S"
_REQUIRED_CHANNELS = ("0", "1")


class SidecarError(ValueError):
    pass


@dataclass(frozen=True)
class ChannelsSidecar:
    version: int
    call_id: str
    channels: dict[str, str]     # "0" → «Я», "1" → собеседник
    brief: str | None


def sidecar_path(audio: Path) -> Path:
    return audio.with_name(audio.stem + SIDECAR_SUFFIX)


def find_sidecar(audio: Path) -> Path | None:
    """Сайдкар рядом с аудио или None. Аудио к этому моменту может быть уже перенесено —
    проверяется только сам сайдкар."""
    path = sidecar_path(Path(audio))
    return path if path.is_file() else None


def read_sidecar(path: Path) -> ChannelsSidecar:
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise SidecarError(f"{Path(path).name}: не читается — {e}") from e
    if not isinstance(raw, dict):
        raise SidecarError(f"{Path(path).name}: ожидался объект")
    if raw.get("version") != 1:
        raise SidecarError(f"{Path(path).name}: version={raw.get('version')!r}, поддерживается 1")
    call_id = raw.get("call_id")
    if not isinstance(call_id, str):
        raise SidecarError(f"{Path(path).name}: call_id не строка")
    channels = raw.get("channels")
    if not isinstance(channels, dict):
        raise SidecarError(f"{Path(path).name}: channels не объект")
    for key in _REQUIRED_CHANNELS:
        if key not in channels:
            raise SidecarError(f"{Path(path).name}: нет канала {key!r}")
    if not all(isinstance(k, str) and isinstance(v, str) for k, v in channels.items()):
        raise SidecarError(f"{Path(path).name}: подписи каналов должны быть строками")
    brief = raw.get("brief")
    if brief is not None and not isinstance(brief, str):
        raise SidecarError(f"{Path(path).name}: brief не строка")
    return ChannelsSidecar(version=1, call_id=call_id, channels=dict(channels), brief=brief)


def started_at(sidecar: ChannelsSidecar) -> datetime | None:
    """Начало звонка из call_id (местное время приложения); мусор → None."""
    try:
        return datetime.strptime(sidecar.call_id, CALL_ID_FORMAT).astimezone()
    except ValueError:
        return None


def load_channels(audio: Path, sr: int = 16000) -> np.ndarray:
    """(n, c) float32 при частоте sr. В отличие от audio.load_audio каналы не сводятся."""
    tmp = tempfile.mktemp(suffix=".wav")
    try:
        try:
            subprocess.run(
                ["afconvert", str(audio), "-d", "LEI16", "-f", "WAVE", tmp],
                check=True, capture_output=True,
            )
        except FileNotFoundError as e:  # afconvert отсутствует (не macOS)
            raise AudioDecodeError("afconvert not found (macOS only)") from e
        except subprocess.CalledProcessError as e:
            raise AudioDecodeError(
                f"afconvert failed for {audio}: {e.stderr.decode('utf-8', 'ignore')[:200]}"
            ) from e
        data, src_sr = sf.read(tmp, dtype="float32", always_2d=True)
    finally:
        Path(tmp).unlink(missing_ok=True)
    if src_sr != sr:
        import soxr

        data = soxr.resample(data, src_sr, sr)
    return np.ascontiguousarray(data, dtype=np.float32)


def split_channels(audio: Path, workdir: Path, sr: int = 16000) -> list[Path]:
    """Дорожки в отдельные mono-WAV `ch<i>.wav` (PCM_16, sr). Моно → SidecarError."""
    data = load_channels(audio, sr)
    if data.shape[1] < 2:
        raise SidecarError(f"{Path(audio).name}: моно с сайдкаром каналов")
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    paths = []
    for i in range(data.shape[1]):
        wav = workdir / f"ch{i}.wav"
        sf.write(str(wav), data[:, i], sr, subtype="PCM_16")
        paths.append(wav)
    return paths


def merge_by_time(per_channel: list[list[dict]]) -> list[dict]:
    """Одна лента по "start"; при равном времени — порядок каналов (сортировка стабильна)."""
    merged = [seg for segs in per_channel for seg in segs]
    return sorted(merged, key=lambda s: s.get("start") or 0.0)


def transcribe_channels(audio: Path, sidecar: ChannelsSidecar, transcriber) -> list[dict]:
    """Каждая дорожка — отдельно через transcriber.transcribe(path); speaker — подпись канала."""
    per_channel: list[list[dict]] = []
    with tempfile.TemporaryDirectory(prefix="mlaud-channels-") as tmp:
        wavs = split_channels(Path(audio), Path(tmp))
        for i, wav in enumerate(wavs):
            label = sidecar.channels.get(str(i))
            if label is None:
                raise SidecarError(f"{Path(audio).name}: в аудио {len(wavs)} каналов, "
                                   f"в сайдкаре нет подписи для {i}")
            segs = transcriber.transcribe(str(wav))
            per_channel.append([{**seg, "speaker": label, "channel": i} for seg in segs])
    return merge_by_time(per_channel)
