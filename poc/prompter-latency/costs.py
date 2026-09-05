"""Сводная таблица S5: задержки и стоимость по прайсам шлюзов.

RouterAI отдаёт цены за токен в рублях, OpenRouter — в долларах (и сам считает usage.cost).
Стоимость хода: (prompt − кэш) × prompt + кэш × input_cache_read + completion × completion.
Курс ₽/$ выводится из пары одинаковых моделей на двух шлюзах (deepseek-v4-flash, prompt).

    poc/prompter-latency/.venv/bin/python poc/prompter-latency/costs.py <routerai.key> <openrouter.key>
"""
import json
import statistics
import sys
from pathlib import Path

import httpx

OUT = Path.home() / "ASR/spikes/prompter-latency"
GATEWAYS = {
    "flash-": ("https://routerai.ru/api/v1", "₽"),
    "routerai-": ("https://routerai.ru/api/v1", "₽"),
    "or-": ("https://openrouter.ai/api/v1", "$"),
}


def pricing(base: str, key: str) -> dict:
    data = httpx.get(f"{base}/models", headers={"Authorization": f"Bearer {key}"}, timeout=30).json()["data"]
    def num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return None            # у части моделей OpenRouter цена — список тарифов, пропускаем
    return {m["id"]: {k: num(v) for k, v in (m.get("pricing") or {}).items() if num(v) is not None}
            for m in data}


def turn_cost(row: dict, pr: dict) -> float:
    prompt = row.get("prompt_tokens") or 0
    cached = row.get("cache_read_input_tokens") or 0
    out = row.get("output_tokens") or 0
    return (max(0, prompt - cached) * pr["prompt"] + cached * pr.get("input_cache_read", pr["prompt"])
            + out * pr["completion"])


def main(routerai_key: str, openrouter_key: str) -> None:
    keys = {"https://routerai.ru/api/v1": Path(routerai_key).read_text().strip(),
            "https://openrouter.ai/api/v1": Path(openrouter_key).read_text().strip()}
    prices = {base: pricing(base, k) for base, k in keys.items()}
    rub = prices["https://routerai.ru/api/v1"]["deepseek/deepseek-v4-flash"]["prompt"]
    usd = prices["https://openrouter.ai/api/v1"]["deepseek/deepseek-v4-flash"]["prompt"]
    rate = rub / usd
    print(f"курс по deepseek-v4-flash: {rate:.1f} ₽/$\n")
    print("| прогон | модель | вариант | полный ответ p50 / max, с | первый токен p50, с | первая карточка p50 / max, с | вывод, ток. | рассуждения, ток. | кэш, ток. (медиана) | за ход | за час (12 ходов) | ≈ $ за час |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for p in sorted(OUT.glob("*.summary.json")):
        s = json.loads(p.read_text())
        name = s["name"]
        gw = next((v for k, v in GATEWAYS.items() if name.startswith(k)), None)
        if gw is None:
            continue
        base, cur = gw
        pr = prices[base].get(s["model"])
        rows = s["rows"]
        secs = [r["sec"] for r in rows]
        ttft = [r["ttft"] for r in rows if r.get("ttft") is not None]
        first = [r["first_card"] for r in rows if r.get("first_card") is not None]
        reasoning = [r.get("reasoning_tokens") or 0 for r in rows]
        cached = [r.get("cache_read_input_tokens") or 0 for r in rows]
        variant = ("коротко, без рассуждений" if s.get("terse") else
                   "без рассуждений" if s.get("reasoning") == {"enabled": False} else "как есть")
        if pr:
            costs = [turn_cost(r, pr) for r in rows]
            steady = statistics.mean(costs[1:]) if len(costs) > 1 else costs[0]
            hour = steady * 12
            hour_usd = hour / rate if cur == "₽" else hour
            cost_txt = f"{steady:.3f} {cur} | {hour:.2f} {cur} | {hour_usd:.3f}"
        else:
            cost_txt = "нет прайса | | "
        print(f"| {name} | {s['model']} | {variant} | {statistics.median(secs):.1f} / {max(secs):.1f} | "
              f"{statistics.median(ttft):.1f}" if ttft else f"| {name} | {s['model']} | {variant} | {statistics.median(secs):.1f} / {max(secs):.1f} | —",
              end="")
        print(f" | {(f'{statistics.median(first):.1f} / {max(first):.1f}') if first else '—'} | "
              f"{round(statistics.mean(r['output_tokens'] for r in rows))} | {round(statistics.mean(reasoning))} | "
              f"{round(statistics.median(cached))} | {cost_txt} |")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
