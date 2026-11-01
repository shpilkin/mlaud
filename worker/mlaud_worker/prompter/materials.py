"""Материалы брифа: извлечение текста и оценка токенов (stage4-brief §3.4, FR-12.5).
Единственный извлекатель для редактора — Swift показывает только отчёт (решение D4)."""

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

SUPPORTED = ("md", "txt", "srt", "pdf", "docx", "rtf", "html")
SCAN_CHARS_PER_PAGE = 20       # среднее < 20 непробельных символов на страницу → скан
NO_TEXT_LAYER = "нет текстового слоя, пропущен"
UNSUPPORTED = "тип не поддерживается"


@dataclass
class Material:
    name: str
    kind: str
    text: str
    tokens: int
    warning: Optional[str] = None      # warning → text == ""

    def report_json(self) -> dict:
        return {"name": self.name, "kind": self.kind, "tokens": self.tokens,
                "warning": self.warning}


def estimate_tokens(text: str) -> int:
    """Одна эвристика на оба языка: (число Unicode-скаляров + 2) // 3 (§3.4)."""
    return (len(text) + 2) // 3


def _srt_text(data: str) -> str:
    """Убрать номера и тайм-коды, оставить текст построчно."""
    lines = []
    for line in data.splitlines():
        stripped = line.strip()
        if not stripped or stripped.isdigit():
            continue
        if "-->" in stripped:
            continue
        lines.append(stripped)
    return "\n".join(lines)


def _pdf_text(data: bytes) -> str:
    from pypdf import PdfReader          # ставится §0.1; тесты при отсутствии — importorskip
    import io
    reader = PdfReader(io.BytesIO(data))
    return "\n".join((page.extract_text() or "") for page in reader.pages)


def _textutil_text(path: Path, textutil: Path) -> str:
    result = subprocess.run(
        [str(textutil), "-convert", "txt", "-stdout", str(path)],
        capture_output=True, timeout=30, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"textutil вернул {result.returncode}")
    return result.stdout.decode("utf-8", errors="replace")


_extract_cache: dict = {}


def extract(path: Path, *, textutil: Path = Path("/usr/bin/textutil")) -> Material:
    """Извлечение одного файла; результат кешируется по пути+mtime — старт процесса зовёт
    scan() и load_materials() по одним и тем же файлам, textutil гонять дважды незачем."""
    cache_key = None
    try:
        stat = path.stat()
        cache_key = (stat.st_mtime_ns, stat.st_size)
        cached = _extract_cache.get(str(path))
        if cached and cached[0] == cache_key:
            return cached[1]
    except OSError:
        cache_key = None
    material = _extract_uncached(path, textutil)
    if cache_key is not None:
        _extract_cache[str(path)] = (cache_key, material)
    return material


def _extract_uncached(path: Path, textutil: Path) -> Material:
    kind = path.suffix.lstrip(".").lower()
    if kind not in SUPPORTED:
        return Material(name=path.name, kind=kind, text="", tokens=0, warning=UNSUPPORTED)
    try:
        if kind in ("md", "txt"):
            text = path.read_text(encoding="utf-8")
        elif kind == "srt":
            text = _srt_text(path.read_text(encoding="utf-8"))
        elif kind == "pdf":
            text = _pdf_text(path.read_bytes())
            pages = max(1, _pdf_page_count(path.read_bytes()))
            if len("".join(text.split())) / pages < SCAN_CHARS_PER_PAGE:
                return Material(name=path.name, kind=kind, text="", tokens=0, warning=NO_TEXT_LAYER)
        else:
            text = _textutil_text(path, textutil)
    except Exception as e:                                   # извлечение не должно ронять отчёт
        return Material(name=path.name, kind=kind, text="", tokens=0,
                        warning=f"не извлеклось: {type(e).__name__}")
    text = text.strip()
    return Material(name=path.name, kind=kind, text=text, tokens=estimate_tokens(text))


def _pdf_page_count(data: bytes) -> int:
    from pypdf import PdfReader
    import io
    return len(PdfReader(io.BytesIO(data)).pages)


def scan(materials_dir: Path) -> list:
    """Все файлы каталога: извлечённые и предупреждённые, по возрастанию tokens."""
    if not materials_dir.exists():
        return []
    materials = [extract(p) for p in sorted(materials_dir.iterdir()) if p.is_file()]
    return sorted(materials, key=lambda m: (m.tokens, m.name))


def load_materials(materials_dir: Path, *, budget: int) -> tuple:
    """(материалы в промт по возрастанию tokens, имена over). Превышение бюджета — самые
    большие файлы с конца помечаются over и в промт не идут (FP:146-147); предупреждённые
    не идут вовсе. over — имена; предупреждённые ищет scan()."""
    usable = [m for m in scan(materials_dir) if m.warning is None]
    included = list(usable)
    over: list = []
    while included and sum(m.tokens for m in included) > budget:
        biggest = included.pop()
        over.append(biggest.name)
    return included, sorted(over)


def report(materials_dir: Path, *, budget: int) -> dict:
    """Форма §2.4 --materials; total — токены попавших в промт."""
    all_materials = scan(materials_dir)
    usable = [m for m in all_materials if m.warning is None]
    over: list = []
    while usable and sum(m.tokens for m in usable) > budget:
        over.append(usable.pop().name)
    return {
        "materials": [m.report_json() for m in all_materials],
        "total": sum(m.tokens for m in usable),
        "budget": budget,
        "over": sorted(over),
    }
