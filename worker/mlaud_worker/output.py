"""Форматирование и запись результатов: .txt (с тайм-кодами) и .srt."""

from pathlib import Path


def format_timestamp(seconds: float, sep: str = ",") -> str:
    """HH:MM:SS{sep}mmm. SRT использует запятую; для .txt передаём sep='.'."""
    if seconds < 0:
        seconds = 0.0
    total_ms = int(round(seconds * 1000))
    ms = total_ms % 1000
    total_s = total_ms // 1000
    s = total_s % 60
    m = (total_s // 60) % 60
    h = total_s // 3600
    return f"{h:02d}:{m:02d}:{s:02d}{sep}{ms:03d}"


def _with_speaker(seg: dict) -> str:
    """Текст сегмента с префиксом спикера, если диаризация его проставила."""
    text = seg["text"].strip()
    speaker = seg.get("speaker")
    return f"{speaker}: {text}" if speaker else text


def build_txt(segments: list[dict]) -> str:
    """Человекочитаемый текст: каждая строка — [HH:MM:SS] (Спикер N:) текст сегмента."""
    lines = []
    for seg in segments:
        stamp = format_timestamp(seg["start"], sep=".")[:8]  # HH:MM:SS без мс
        if seg["text"].strip():
            lines.append(f"[{stamp}] {_with_speaker(seg)}")
    return "\n".join(lines) + ("\n" if lines else "")


def build_srt(segments: list[dict]) -> str:
    """Стандартный SRT. Спикер (если есть) — префиксом текстовой строки."""
    blocks = []
    idx = 1
    for seg in segments:
        if not seg["text"].strip():
            continue
        start = format_timestamp(seg["start"], sep=",")
        end = format_timestamp(seg["end"], sep=",")
        blocks.append(f"{idx}\n{start} --> {end}\n{_with_speaker(seg)}\n")
        idx += 1
    return "\n".join(blocks)


def write_outputs(segments: list[dict], out_dir: Path, base_name: str) -> dict:
    """Записать .txt и .srt в out_dir. Создаёт каталог. Возвращает пути."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    txt_path = out_dir / f"{base_name}.txt"
    srt_path = out_dir / f"{base_name}.srt"
    txt_path.write_text(build_txt(segments), encoding="utf-8")
    srt_path.write_text(build_srt(segments), encoding="utf-8")
    return {"txt": txt_path, "srt": srt_path}
