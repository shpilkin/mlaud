"""S5 — задержка и цена первой карточки суфлёра (OQ-16).

Одна беседа на звонок (feature-prompter.md §7.2): системный промт = роль + профиль + бриф +
материалы (~30 тыс. токенов) за точкой кэша; каждый ход — новые реплики из реальной
расшифровки + прошедшее время; ответ — JSON карточек по схеме; ответ модели остаётся в
истории как ход ассистента. Меряем полное время ответа на ход (не токены в секунду),
usage и стоимость.

Кандидаты: claude-opus-5 (адаптивное мышление, effort low), claude-sonnet-5 (то же),
claude-haiku-4-5 (без мышления и effort — не кандидат, а точка для масштаба),
локальный llama.cpp (OpenAI-совместимый, ~/my_projects/local llm).

Ключ Anthropic — из ~/my_projects/email_reader/.env (в окружении нет); значение нигде не
печатается. Цены — таблица справочника claude-api на 2026-06: opus 5 $5/$25, sonnet 5 $2/$10,
haiku 4.5 $1/$5 за 1M; кэш: запись ×1.25, чтение ×0.1 (shared/prompt-caching.md).

Запуск:
    poc/prompter-latency/.venv/bin/python poc/prompter-latency/run.py anthropic --model claude-opus-5
    poc/prompter-latency/.venv/bin/python poc/prompter-latency/run.py openai --base-url http://127.0.0.1:8080
    poc/prompter-latency/.venv/bin/python poc/prompter-latency/run.py report
Сырые ответы — ~/ASR/spikes/prompter-latency/.
"""

import argparse
import json
import re
import statistics
import time
from pathlib import Path

HOME = Path.home()
OUT = HOME / "ASR/spikes/prompter-latency"
PROTO = HOME / "my_projects/sufler"
ASR_OUT = HOME / "ASR/ASROutput/AllOutputs"

PRICES = {  # $ за 1M токенов: (вход, выход)
    "claude-opus-5": (5.0, 25.0),
    "claude-sonnet-5": (2.0, 10.0),
    "claude-haiku-4-5": (1.0, 5.0),
}
CACHE_WRITE = 1.25
CACHE_READ = 0.10
TURNS_PER_HOUR = 12
EXPECTED_MIN = 60

CARDS_SCHEMA = {
    "type": "object",
    "properties": {
        "cards": {
            "type": "array",
            "maxItems": 4,
            "items": {
                "type": "object",
                "properties": {
                    "type": {"type": "string",
                             "enum": ["answer", "ask", "fact", "next_step", "off_route", "tension", "time"]},
                    "priority": {"type": "integer"},
                    "text": {"type": "string"},
                    "detail": {"type": "string"},
                    "source": {"type": "string"},
                },
                "required": ["type", "priority", "text", "detail", "source"],
                "additionalProperties": False,
            },
        },
        "agenda": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "item": {"type": "string"},
                    "status": {"type": "string", "enum": ["pending", "active", "done"]},
                },
                "required": ["item", "status"],
                "additionalProperties": False,
            },
        },
        "flags": {
            "type": "object",
            "properties": {"question_pending": {"type": "boolean"}},
            "required": ["question_pending"],
            "additionalProperties": False,
        },
    },
    "required": ["cards", "agenda", "flags"],
    "additionalProperties": False,
}

INSTRUCTIONS = """Ты — суфлёр в живом деловом разговоре. Ты работаешь в реальном времени и помогаешь
ПОЛЬЗОВАТЕЛЮ (реплики с пометкой «Я»), пока он говорит с собеседником.

На каждый ход тебе приходят новые реплики с момента прошлого хода и прошедшее время. Верни
JSON строго по схеме: карточки-подсказки, состояние повестки и флаги.

Правила карточек:
- text — не длиннее 140 символов, по-русски, читается одним взглядом; detail — раскрытие
  по клику (может быть пустым); source — имя материала, если факт взят из материалов, иначе "".
- Не больше 4 карточек за ход, самое важное — priority 1. Если подсказывать нечего — пустой
  список.
- Не повторяй карточки, которые уже показывал, если ситуация не изменилась.
- Типы: answer — что ответить на вопрос собеседника; ask — что спросить; fact — факт или
  цифра из материалов; next_step — следующий шаг по маршруту; off_route — ушли с повестки;
  tension — напряжение или возражение и как сгладить; time — про время и повестку.
- agenda — все пункты повестки брифа с состоянием pending / active / done по разговору.
- flags.question_pending — собеседник задал вопрос, на который «Я» ещё не ответил.
"""

BRIEF = """# Бриф

---
title: Пример — обсуждение архитектуры с коллегой
template: meeting
mode: vks
expected_min: 60
counterpart: коллега
goal: договориться о подходе и зафиксировать следующий шаг
agenda:
  - Зачем встреча и что уже проговорили (5)
  - Текущее состояние (15)
  - Варианты решения (20)
  - Ограничения (10)
  - Решения и следующий шаг (10)
prompter: on
---

## Задача встречи
Выйти с одним согласованным следующим шагом.

## Собеседник
Коллега, специалист в своей области.

## Скрипт
1. Кратко зафиксировать, что уже обсуждали.
2. Пройти варианты решения по очереди.
3. Отдельно — ограничения.
4. Закрыть решением и владельцем следующего шага.

## Учитывать / избегать
Не обещать сроков; держаться повестки.
"""


NITI_ROOT = HOME / "my_projects/email_reader"


def niti_connection(name: str) -> tuple[str, str, str]:
    """Подключение Niti по имени: (base_url, model, key). Ключ расшифровывается кодом самого
    Niti в его окружении и живёт только в памяти этого процесса — на диск и в лог не попадает."""
    import sqlite3
    import subprocess

    db = HOME / "Library/Application Support/EmailReader/email_reader.db"
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    row = con.execute("select base_url, model, api_key_enc from model_connections where name = ?",
                      (name,)).fetchone()
    if row is None:
        raise SystemExit(f"в Niti нет подключения «{name}»")
    base_url, model, enc = row
    proc = subprocess.run(
        [str(NITI_ROOT / ".venv/bin/python"), "-c",
         "import sys; from email_reader.crypto import decrypt; sys.stdout.write(decrypt(sys.stdin.read()))"],
        input=enc, capture_output=True, text=True, cwd=str(NITI_ROOT), check=True)
    return base_url, model, proc.stdout.strip()


def load_key() -> str:
    env = HOME / "my_projects/email_reader/.env"
    for line in env.read_text().splitlines():
        if line.startswith("ANTHROPIC_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit("ANTHROPIC_API_KEY не найден в email_reader/.env")


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


TERSE_RULES = """
Режим коротких ответов (важно для задержки):
- detail — всегда пустая строка: подробности запрашиваются отдельно, не в живом ходе.
- Не больше 3 карточек; text — не длиннее 100 символов.
- agenda — только пункты, чьё состояние изменилось с прошлого хода; если ничего не
  изменилось — пустой список.
"""


def build_system_blocks(include_second_transcript: bool, terse: bool = False) -> list[dict]:
    """Стабильная часть промта — один список блоков, точка кэша на последнем."""
    profile = read(PROTO / "config/profile.md")
    materials = [
        ("Описание продуктов (products.md)",
         read(PROTO / "products.md")),
        ("Расшифровка прошлой встречи: 17.08 заметка.txt",
         read(ASR_OUT / "2026-08" / "17.08 заметка.txt")),
    ]
    if include_second_transcript:
        materials.append(("Расшифровка прошлой встречи: 17.08 встреча.txt",
                          read(ASR_OUT / "2026-08" / "17.08 встреча.txt")))
    head = INSTRUCTIONS + (TERSE_RULES if terse else "") + "\n=== ПРОФИЛЬ ПОЛЬЗОВАТЕЛЯ ===\n" + profile + "\n=== БРИФ ===\n" + BRIEF
    mats = "\n=== МАТЕРИАЛЫ БРИФА ===\n" + "\n\n".join(
        f"--- {name} ---\n{text}" for name, text in materials)
    return [
        {"type": "text", "text": head},
        {"type": "text", "text": mats, "cache_control": {"type": "ephemeral"}},
    ]


LINE_RE = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] ([^:]+): (.*)$")


def build_turns(n: int = 10) -> list[dict]:
    """Реплики реальной расшифровки, нарезанные на n ходов подряд."""
    src = ASR_OUT / "2026-09" / "2026-09-03_16-18-10_Запись 14.txt"
    lines = []
    for raw in read(src).splitlines():
        m = LINE_RE.match(raw)
        if not m:
            continue
        sec = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        who = m.group(4).strip()
        label = "Я" if who.lower() == "я" else "Собеседник"
        text = m.group(5).strip()
        if text:
            lines.append((sec, label, text))
    # Первые ~25 минут разговора, по ~2.5 минуты на ход: реплик в ходе столько, сколько
    # набегает за это время в живом звонке.
    span = 150
    turns = []
    for i in range(n):
        lo, hi = i * span, (i + 1) * span
        chunk = [l for l in lines if lo <= l[0] < hi]
        elapsed_min = round(hi / 60)
        body = "\n".join(f"{label}: {text}" for _, label, text in chunk) or "(тишина)"
        turns.append({
            "elapsed_min": elapsed_min,
            "lines": len(chunk),
            "text": f"Прошло {elapsed_min} мин из {EXPECTED_MIN}.\nНовые реплики:\n{body}\n\nДай подсказки для «Я» по правилам и схеме.",
        })
    return turns


def cost_usd(model: str, usage: dict) -> float:
    inp, out = PRICES[model]
    return (usage.get("input_tokens", 0) * inp
            + usage.get("cache_creation_input_tokens", 0) * inp * CACHE_WRITE
            + usage.get("cache_read_input_tokens", 0) * inp * CACHE_READ
            + usage.get("output_tokens", 0) * out) / 1e6


def run_anthropic(model: str, turns: list[dict], effort: str, second_transcript: bool,
                  label: str | None) -> dict:
    import anthropic

    client = anthropic.Anthropic(api_key=load_key())
    system = build_system_blocks(second_transcript)
    thinking_kwargs = {}
    output_config = {"format": {"type": "json_schema", "schema": CARDS_SCHEMA}}
    if model != "claude-haiku-4-5":
        thinking_kwargs["thinking"] = {"type": "adaptive"}
        output_config["effort"] = effort

    counted = client.messages.count_tokens(
        model=model, system=system, messages=[{"role": "user", "content": "—"}]).input_tokens
    print(f"[{model}] системный промт: {counted} токенов")

    # Прогрев: та же стабильная часть, тот же режим — чтобы первый измеряемый ход читал кэш,
    # как в приложении при открытии экрана звонка.
    t = time.perf_counter()
    warm = client.messages.create(
        model=model, max_tokens=64, system=system,
        messages=[{"role": "user", "content": "Подтверди готовность одним словом."}],
        output_config={k: v for k, v in output_config.items() if k != "format"} or None,
        **thinking_kwargs) if model != "claude-haiku-4-5" else client.messages.create(
        model=model, max_tokens=64, system=system,
        messages=[{"role": "user", "content": "Подтверди готовность одним словом."}])
    warm_sec = time.perf_counter() - t
    wu = warm.usage.to_dict()
    print(f"[{model}] прогрев {warm_sec:.1f} с: cache_creation={wu.get('cache_creation_input_tokens')}, "
          f"cache_read={wu.get('cache_read_input_tokens')}, input={wu.get('input_tokens')}")

    rows = []
    messages: list[dict] = []
    name = label or model
    raw = open(OUT / f"{name}.jsonl", "w", encoding="utf-8")
    for i, turn in enumerate(turns, 1):
        messages.append({"role": "user", "content": turn["text"]})
        t = time.perf_counter()
        resp = client.messages.create(
            model=model, max_tokens=4000, system=system, messages=messages,
            output_config=output_config, cache_control={"type": "ephemeral"}, **thinking_kwargs)
        sec = time.perf_counter() - t
        text = next(b.text for b in resp.content if b.type == "text")
        data = json.loads(text)
        messages.append({"role": "assistant", "content": text})
        u = resp.usage.to_dict()
        row = {
            "turn": i, "sec": round(sec, 2), "lines": turn["lines"], "cards": len(data["cards"]),
            "input_tokens": u.get("input_tokens", 0),
            "cache_creation_input_tokens": u.get("cache_creation_input_tokens", 0),
            "cache_read_input_tokens": u.get("cache_read_input_tokens", 0),
            "output_tokens": u.get("output_tokens", 0),
            "cost_usd": round(cost_usd(model, u), 5), "stop_reason": resp.stop_reason,
        }
        rows.append(row)
        raw.write(json.dumps({"turn": i, "request": turn["text"], "response": data, "usage": u,
                              "sec": sec}, ensure_ascii=False) + "\n")
        raw.flush()
        print(f"[{model}] ход {i}: {sec:.2f} с, карточек {len(data['cards'])}, "
              f"cache_read={row['cache_read_input_tokens']}, write={row['cache_creation_input_tokens']}, "
              f"in={row['input_tokens']}, out={row['output_tokens']}, ${row['cost_usd']:.4f}")
        if i >= 2 and row["cache_read_input_tokens"] == 0:
            raise SystemExit(f"[{model}] кэш не читается на ходе {i} — прогон измеряет не то, стоп")
    raw.close()
    summary = summarize(name, model, counted, warm_sec, rows)
    (OUT / f"{name}.summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return summary


def summarize(name, model, system_tokens, warm_sec, rows, extra=None):
    secs = [r["sec"] for r in rows]
    steady = rows[1:] if len(rows) > 1 else rows
    per_turn_cost = statistics.mean(r["cost_usd"] for r in steady) if steady else 0.0
    s = {
        "name": name, "model": model, "system_tokens": system_tokens,
        "warm_sec": round(warm_sec, 2), "turns": len(rows),
        "latency_median": round(statistics.median(secs), 2), "latency_max": round(max(secs), 2),
        "latency_min": round(min(secs), 2),
        "cost_total_usd": round(sum(r["cost_usd"] for r in rows), 4),
        "cost_per_turn_steady_usd": round(per_turn_cost, 4),
        "cost_per_hour_usd": round(per_turn_cost * TURNS_PER_HOUR, 3),
        "output_tokens_mean": round(statistics.mean(r["output_tokens"] for r in rows)),
        "cache_read_from_turn2": all(r["cache_read_input_tokens"] > 0 for r in rows[1:]),
        "rows": rows,
    }
    if extra:
        s.update(extra)
    return s


class _FakeResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text


def _post_stream(client, endpoint: str, body: dict, t0: float):
    """SSE-стрим: собирает полный ответ и засекает первый токен и первую целую карточку.

    Первая карточка — момент, когда в накопленном тексте закрылся первый объект внутри
    "cards": [ … ]. Считаем по балансу скобок после ключа cards — для JSON без вложенных
    объектов в карточке этого достаточно.
    """
    acc = ""
    ttft = first_card = None
    usage = None
    depth = None            # глубина скобок внутри массива cards; None — массив ещё не начался
    with client.stream("POST", endpoint, json=body) as r:
        if r.status_code >= 400:
            r.read()
            return _FakeResponse(r.status_code, r.text), None, None, None
        for line in r.iter_lines():
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if chunk.get("usage"):
                usage = chunk["usage"]
            for ch in chunk.get("choices", []):
                delta = (ch.get("delta") or {}).get("content") or ""
                if not delta:
                    continue
                if ttft is None:
                    ttft = time.perf_counter() - t0
                acc += delta
                if first_card is None:
                    idx = acc.find('"cards"')
                    if idx >= 0:
                        arr = acc.find("[", idx)
                        if arr >= 0:
                            depth = 0
                            for c in acc[arr + 1:]:
                                if c == "{":
                                    depth += 1
                                elif c == "}":
                                    depth -= 1
                                    if depth == 0:
                                        first_card = time.perf_counter() - t0
                                        break
    j = {"choices": [{"message": {"content": acc}}], "usage": usage or {}}
    return _FakeResponse(200, acc), j, ttft, first_card


def run_openai_compat(base_url: str, model: str, turns: list[dict], second_transcript: bool,
                     label: str, api_key: str | None = None, price_in: float = 0.0,
                     price_out: float = 0.0, cache_read_ratio: float = 0.1,
                     cache_control: bool = False, reasoning_effort: str | None = None,
                     reasoning: dict | None = None, stream: bool = False, terse: bool = False) -> dict:
    """OpenAI-совместимый эндпоинт: локальный llama.cpp, OpenRouter, RouterAI, Corp LiteLLM.

    Кэш промта здесь не наш: у llama.cpp — `cache_prompt` (общий префикс не пересчитывается),
    у DeepSeek — автоматический (usage.prompt_cache_hit_tokens), у OpenAI-стиля —
    usage.prompt_tokens_details.cached_tokens. Читаем, что отдали, и считаем стоимость по
    ценам из аргументов (чтение кэша — по `cache_read_ratio` от входа).
    """
    import httpx

    system_text = "".join(b["text"] for b in build_system_blocks(second_transcript, terse))
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    client = httpx.Client(base_url=base_url, timeout=600.0, headers=headers)
    # У шлюзов base_url уже содержит /v1, у llama.cpp — только хост.
    endpoint = "/chat/completions" if base_url.rstrip("/").endswith("/v1") else "/v1/chat/completions"
    rows = []
    if cache_control:
        # Формат OpenRouter для Anthropic: cache_control на блоке системного сообщения.
        system_msg = {"role": "system", "content": [
            {"type": "text", "text": system_text, "cache_control": {"type": "ephemeral"}}]}
    else:
        system_msg = {"role": "system", "content": system_text}
    messages = [system_msg]
    raw = open(OUT / f"{label}.jsonl", "w", encoding="utf-8")
    prompt_tokens_first = None
    is_local = "127.0.0.1" in base_url or "localhost" in base_url
    is_openrouter = "openrouter.ai" in base_url
    schema_format = {"type": "json_schema", "json_schema": {"name": "cards", "schema": CARDS_SCHEMA}}
    # Цепочка на случай, если шлюз не принимает формат: json_schema → json_object → без формата.
    formats = [schema_format, {"type": "json_object"}, None]
    fmt_idx = 0
    schema_hint = "\n\nОтвет — только JSON по схеме, без пояснений и без ```:\n" + json.dumps(CARDS_SCHEMA, ensure_ascii=False)
    for i, turn in enumerate(turns, 1):
        content = turn["text"] + (schema_hint if fmt_idx > 0 else "")
        messages.append({"role": "user", "content": content})
        while True:
            body = {"model": model, "messages": messages, "max_tokens": 4000, "temperature": 0.3}
            if formats[fmt_idx] is not None:
                body["response_format"] = formats[fmt_idx]
            if reasoning_effort:
                body["reasoning_effort"] = reasoning_effort
            if reasoning is not None:
                body["reasoning"] = reasoning        # объект OpenRouter: {"effort": …} / {"enabled": false}
            if is_local:
                body["cache_prompt"] = True          # параметр llama.cpp; шлюзы могут не принять
            if is_openrouter:
                body["usage"] = {"include": True}    # OpenRouter отдаёт cost и cached_tokens
            ttft = first_card_at = None
            t = time.perf_counter()
            if stream:
                body["stream"] = True
                body["stream_options"] = {"include_usage": True}
                r, j, ttft, first_card_at = _post_stream(client, endpoint, body, t)
            else:
                r = client.post(endpoint, json=body)
                j = None
            sec = time.perf_counter() - t
            if r.status_code in (400, 422) and i == 1 and fmt_idx < len(formats) - 1:
                print(f"[{label}] формат {formats[fmt_idx]} отвергнут ({r.status_code}): {r.text[:200]} — следующий")
                fmt_idx += 1
                messages[-1]["content"] = turn["text"] + schema_hint
                continue
            break
        if r.status_code >= 400:
            raise SystemExit(f"[{label}] HTTP {r.status_code}: {r.text[:500]}")
        if j is None:
            j = r.json()
        text = j["choices"][0]["message"]["content"] or ""
        text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
        # Первый JSON-объект; хвост после него (шлюз иногда дописывает текст) — в лог, не в ошибку.
        data, end = json.JSONDecoder().raw_decode(text)
        extra = text[end:].strip()
        if extra:
            print(f"[{label}] ход {i}: после JSON ещё {len(extra)} символов — отброшены: {extra[:80]!r}")
        text = text[:end]
        messages.append({"role": "assistant", "content": text})
        usage = j.get("usage", {}) or {}
        timings = j.get("timings", {}) or {}
        details = usage.get("prompt_tokens_details") or {}
        cached = (usage.get("prompt_cache_hit_tokens")
                  or details.get("cached_tokens")
                  or usage.get("cache_read_input_tokens")
                  or (usage.get("prompt_tokens", 0) - timings["prompt_n"] if timings.get("prompt_n") is not None else 0)
                  or 0)
        if prompt_tokens_first is None:
            prompt_tokens_first = usage.get("prompt_tokens")
        uncached = max(0, usage.get("prompt_tokens", 0) - cached)
        cost = (uncached * price_in + cached * price_in * cache_read_ratio
                + usage.get("completion_tokens", 0) * price_out) / 1e6
        if isinstance(usage.get("cost"), (int, float)):
            cost = float(usage["cost"])          # шлюз посчитал сам (OpenRouter) — верим ему
        row = {
            "turn": i, "sec": round(sec, 2), "lines": turn["lines"], "cards": len(data["cards"]),
            "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": usage.get("completion_tokens"),
            "prompt_n_processed": timings.get("prompt_n"), "prompt_ms": timings.get("prompt_ms"),
            "predicted_n": timings.get("predicted_n"), "predicted_ms": timings.get("predicted_ms"),
            "cost_usd": round(cost, 5), "output_tokens": usage.get("completion_tokens", 0),
            "cache_read_input_tokens": cached,
            "reasoning_tokens": (usage.get("completion_tokens_details") or {}).get("reasoning_tokens"),
            "ttft": round(ttft, 2) if ttft is not None else None,
            "first_card": round(first_card_at, 2) if first_card_at is not None else None,
        }
        rows.append(row)
        raw.write(json.dumps({"turn": i, "response": data, "usage": usage, "timings": timings,
                              "sec": sec}, ensure_ascii=False) + "\n")
        raw.flush()
        print(f"[{label}] ход {i}: {sec:.2f} с (ttft {row['ttft']}, первая карточка {row['first_card']}), "
              f"карточек {len(data['cards'])}, prompt={row['prompt_tokens']} (кэш {cached}), "
              f"out={row['output_tokens']} (reasoning {row['reasoning_tokens']}), cost={row['cost_usd']:.4f}")
    raw.close()
    ttfts = [r["ttft"] for r in rows if r.get("ttft") is not None]
    firsts = [r["first_card"] for r in rows if r.get("first_card") is not None]
    summary = summarize(label, model, prompt_tokens_first, 0.0, rows,
                        extra={"prompt_ms_first": rows[0]["prompt_ms"], "base_url": base_url,
                               "response_format": formats[fmt_idx], "cache_control": cache_control,
                               "reasoning_effort": reasoning_effort, "reasoning": reasoning,
                               "stream": stream, "terse": terse,
                               "ttft_median": round(statistics.median(ttfts), 2) if ttfts else None,
                               "first_card_median": round(statistics.median(firsts), 2) if firsts else None,
                               "first_card_max": round(max(firsts), 2) if firsts else None})
    (OUT / f"{label}.summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return summary


def report() -> str:
    rows = [json.loads(p.read_text()) for p in sorted(OUT.glob("*.summary.json"))]
    lines = ["| модель | промт, ток. | прогрев, с | ход: медиана / макс, с | вывод, ток. | кэш читается со 2-го хода | $ за ход (устоявш.) | $ за час (12 ходов) | $ за прогон |",
             "|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['name']} | {r['system_tokens']} | {r['warm_sec']} | {r['latency_median']} / {r['latency_max']} | "
                     f"{r['output_tokens_mean']} | {'да' if r['cache_read_from_turn2'] else 'нет'} | "
                     f"{r['cost_per_turn_steady_usd']} | {r['cost_per_hour_usd']} | {r['cost_total_usd']} |")
    text = "\n".join(lines)
    print(text)
    return text


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("anthropic")
    a.add_argument("--model", required=True)
    a.add_argument("--effort", default="low")
    a.add_argument("--turns", type=int, default=10)
    a.add_argument("--second-transcript", action="store_true")
    a.add_argument("--label")
    c = sub.add_parser("count")
    c.add_argument("--model", default="claude-opus-5")
    c.add_argument("--second-transcript", action="store_true")
    l = sub.add_parser("openai", help="OpenAI-совместимый эндпоинт: llama.cpp, OpenRouter, RouterAI, LiteLLM")
    l.add_argument("--base-url", default="http://127.0.0.1:8080")
    l.add_argument("--model", default="local")
    l.add_argument("--turns", type=int, default=10)
    l.add_argument("--second-transcript", action="store_true")
    l.add_argument("--label", default="local-qwen3.6-35b-a3b")
    l.add_argument("--key-file", help="файл с ключом (одна строка); значение не печатается")
    l.add_argument("--niti-connection", help="взять base_url, модель и ключ из подключения Niti с этим именем")
    l.add_argument("--price-in", type=float, default=0.0, help="$ за 1M входных токенов")
    l.add_argument("--price-out", type=float, default=0.0, help="$ за 1M выходных токенов")
    l.add_argument("--cache-read-ratio", type=float, default=0.1)
    l.add_argument("--cache-control", action="store_true", help="cache_control на системном сообщении (формат OpenRouter/Anthropic)")
    l.add_argument("--reasoning-effort", help="reasoning_effort в теле запроса (low/medium/high), если шлюз понимает")
    l.add_argument("--reasoning-json", help='объект reasoning как JSON, напр. {"effort":"low"} или {"enabled":false}')
    l.add_argument("--stream", action="store_true", help="стрим: мерить первый токен и первую целую карточку")
    l.add_argument("--terse", action="store_true", help="короткие ответы: без detail, ≤3 карточек, agenda только изменения")
    sub.add_parser("report")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.cmd == "count":
        import anthropic
        client = anthropic.Anthropic(api_key=load_key())
        system = build_system_blocks(args.second_transcript)
        n = client.messages.count_tokens(model=args.model, system=system,
                                         messages=[{"role": "user", "content": "—"}]).input_tokens
        turns = build_turns()
        print(f"системный промт: {n} токенов; ходов {len(turns)}, реплик по ходам: {[t['lines'] for t in turns]}")
    elif args.cmd == "anthropic":
        run_anthropic(args.model, build_turns(args.turns), args.effort, args.second_transcript, args.label)
    elif args.cmd == "openai":
        base_url, model = args.base_url, args.model
        key = Path(args.key_file).read_text().strip() if args.key_file else None
        if args.niti_connection:
            base_url, model, key = niti_connection(args.niti_connection)
            print(f"[{args.label}] подключение Niti «{args.niti_connection}»: {base_url} / {model}")
        run_openai_compat(base_url, model, build_turns(args.turns), args.second_transcript,
                          args.label, api_key=key, price_in=args.price_in, price_out=args.price_out,
                          cache_read_ratio=args.cache_read_ratio, cache_control=args.cache_control,
                          reasoning_effort=args.reasoning_effort,
                          reasoning=json.loads(args.reasoning_json) if args.reasoning_json else None,
                          stream=args.stream, terse=args.terse)
    else:
        report()


if __name__ == "__main__":
    main()
