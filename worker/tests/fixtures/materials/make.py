"""Генерация бинарных фикстур материалов (stage4-brief §3.8): текстовый PDF, скан-PDF без
текстового слоя, docx/rtf через системный textutil. Запуск: python3 make.py (из этого
каталога). Текст PDF — латиница: простой Tj-поток не умеет кириллицу, а фикстуре хватает
и того, что текстовый слой есть и извлекается."""

import subprocess
from pathlib import Path

HERE = Path(__file__).parent

PDF_TEXT = ("Ivan Petrov: 6 let sistemnym analitikom, komanda iz treh chelovek. "
            "Keysy: migratsiya otchetnosti, katalog dannyh.")


def _pdf(text: str | None) -> bytes:
    """Минимальный одностраничный PDF; text=None — страница без текстового слоя (скан)."""
    if text is not None:
        safe = text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")
        content = f"BT /F1 12 Tf 72 770 Td ({safe}) Tj ET".encode("latin-1")
    else:
        content = b""
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R "
         b"/Resources << /Font << /F1 5 0 R >> >> >>"),
        b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    xref_pos = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref_pos}\n%%EOF\n").encode()
    return bytes(out)


def main() -> None:
    (HERE / "page.pdf").write_bytes(_pdf(PDF_TEXT))
    (HERE / "scan.pdf").write_bytes(_pdf(None))
    src = HERE / "note.txt"
    subprocess.run(["/usr/bin/textutil", "-convert", "docx", "-output", str(HERE / "doc.docx"),
                    str(src)], check=True)
    subprocess.run(["/usr/bin/textutil", "-convert", "rtf", "-output", str(HERE / "doc.rtf"),
                    str(src)], check=True)
    print("fixtures written:", sorted(p.name for p in HERE.iterdir() if p.suffix != ".py"))


if __name__ == "__main__":
    main()
