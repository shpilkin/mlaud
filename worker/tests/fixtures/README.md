# Фикстуры подсказчика (stage4-brief §3.8)

Общие для Python (`worker/tests/test_prompter_*.py`) и Swift (`MLaudTests/PrompterTests.swift`,
каталог читается через `#filePath` → `../../../worker/tests/fixtures`).

```
brief/ok-full.md, ok-full.json, ok-full.canonical.md          пример FP:272-301 + ожидаемый разбор + каноническая запись
brief/ok-minimal.md, ok-minimal.json, ok-minimal.canonical.md   только title/mode; prompter по умолчанию off
brief/bad-mode.md, bad-no-frontmatter.md                        ошибки разбора
brief/template-interview.md                                     шаблон §3.2 с разделом «Дополнение к промту»
materials/note.md, note.txt, sub.srt, page.pdf, scan.pdf,       по одному файлу каждого типа;
          doc.docx, page.html, doc.rtf, tokens.json             tokens.json: имя → ожидаемые tokens
materials/make.py                                               скрипт, которым сделаны page.pdf/scan.pdf/doc.docx/doc.rtf
prompt/system.golden.txt                                        снимок системного промта для ok-full + note.md
protocol/events.jsonl, commands.jsonl                           строки §2.2/§2.3 дословно
```

Заготовки `brief/`, `materials/`, `prompt/` создаёт группа P1; `protocol/` — Swift Core.
