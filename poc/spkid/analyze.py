"""Шаг 3 замера: работает ли узнавание голоса между файлами.

Отвечает на два вопроса:
  1) Расходятся ли распределения «тот же человек в другом файле» и «другой человек»?
     Если нет — порог не построить, и фича мертва независимо от UI.
  2) Что было бы на практике: gallery собирается из ВСЕХ файлов кроме проверяемого
     (leave-one-file-out), затем кластеры проверяемого файла матчатся с ней.
     Это прямая симуляция боевого сценария, включая «голос в базе отсутствует».
"""

import json
import os
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

OUT = Path(os.environ.get("SPKID_OUT", Path.home() / "ASR/spkid-eval"))
DUP_TOL = 1.0     # файлы с одинаковой длительностью — одна и та же запись в двух форматах
LONG_ENOUGH = 30.0


def load() -> tuple[list[dict], dict]:
    labels = json.loads((OUT / "labels.json").read_text(encoding="utf-8"))
    spk_labels = labels.get("speakers", {})
    channels = labels.get("channels", {})

    canon: dict[str, str] = {}
    clusters, durations, names = [], {}, {}
    for p in sorted((OUT / "data").glob("*.json")):
        rec = json.loads(p.read_text(encoding="utf-8"))
        slug = rec["slug"]
        durations[slug] = rec["duration"]
        names[slug] = rec.get("name", slug)
        cents = np.load(OUT / "data" / f"{slug}.npy")
        for sp in rec["speakers"]:
            mark = spk_labels.get(f"{slug}|{sp['label']}", {})
            name = (mark.get("name") or "").strip()
            if sp["padded"] or mark.get("mixed") or not name:
                continue
            name = canon.setdefault(name.casefold(), name)
            v = cents[sp["index"]].astype(np.float64)
            n = np.linalg.norm(v)
            if n < 1e-6:
                continue
            clusters.append({
                "slug": slug, "label": sp["label"], "name": name,
                "channel": channels.get(slug, "other") or "other",
                "speech_sec": sp["speech_sec"], "emb": v / n,
            })
    return clusters, durations, names


def recording_groups(durations: dict) -> dict[str, str]:
    """Один и тот же митинг, сохранённый дважды, — это не два независимых файла.

    Пары «та же запись в другом формате» нельзя считать кросс-файловыми: аудио почти
    идентично, косинус завышен, и оценка получится оптимистичной.
    """
    group: dict[str, str] = {}
    for slug, d in sorted(durations.items(), key=lambda kv: -kv[1]):
        for other, gid in group.items():
            if abs(durations[other] - d) <= DUP_TOL:
                group[slug] = gid
                break
        else:
            group[slug] = slug
    return group


def pairs(clusters, group, min_speech=0.0):
    """Кросс-файловые пары: (косинус, свой/чужой, канал_a, канал_b)."""
    out = []
    cs = [c for c in clusters if c["speech_sec"] >= min_speech]
    for i in range(len(cs)):
        for j in range(i + 1, len(cs)):
            a, b = cs[i], cs[j]
            if group[a["slug"]] == group[b["slug"]]:
                continue
            out.append((float(a["emb"] @ b["emb"]), a["name"] == b["name"],
                        a["channel"], b["channel"]))
    return out


def eer(scores_pos, scores_neg):
    if not scores_pos or not scores_neg:
        return None, None
    pos, neg = np.array(scores_pos), np.array(scores_neg)
    grid = np.unique(np.concatenate([pos, neg]))
    best = (1.0, None)
    for t in grid:
        frr = float((pos < t).mean())    # свой отвергнут
        far = float((neg >= t).mean())   # чужой принят
        if abs(frr - far) < best[0]:
            best = (abs(frr - far), (t, (frr + far) / 2))
    return best[1] if best[1] else (None, None)


def at_far(scores_pos, scores_neg, target_far):
    """Минимальный порог с долей ложных принятий <= target_far, и его цена в отказах.

    Именно минимальный: FAR убывает с ростом порога, а FRR растёт, поэтому любой более
    высокий порог удовлетворял бы условию, но отвергал бы больше своих без всякой пользы.
    """
    if not scores_pos or not scores_neg:
        return None
    pos, neg = np.array(scores_pos), np.array(scores_neg)
    candidates = np.append(np.unique(np.concatenate([pos, neg])), neg.max() + 1e-6)
    for t in candidates:  # по возрастанию
        far = float((neg >= t).mean())
        if far <= target_far:
            return float(t), far, float((pos < t).mean())
    return None


def loo(clusters, group, thresholds, min_speech=0.0):
    """Leave-one-file-out: галерея из остальных файлов, матчинг кластеров текущего."""
    cs = [c for c in clusters if c["speech_sec"] >= min_speech]
    stats = {t: defaultdict(int) for t in thresholds}
    for slug in sorted({c["slug"] for c in cs}):
        gid = group[slug]
        gallery_src = defaultdict(list)
        for c in cs:
            if group[c["slug"]] != gid:
                gallery_src[c["name"]].append(c["emb"])
        if not gallery_src:
            continue
        names = list(gallery_src)
        means = [np.mean(gallery_src[n], axis=0) for n in names]
        G = np.stack([m / np.linalg.norm(m) for m in means])
        for c in [x for x in cs if x["slug"] == slug]:
            scores = G @ c["emb"]
            k = int(np.argmax(scores))
            top, guess = float(scores[k]), names[k]
            known = c["name"] in gallery_src
            for t in thresholds:
                s = stats[t]
                if top >= t:
                    if not known:
                        s["чужого приняли за своего"] += 1
                    elif guess == c["name"]:
                        s["верно названо"] += 1
                    else:
                        s["перепутаны люди"] += 1
                else:
                    s["корректный отказ" if not known else "свой не узнан"] += 1
    return stats


def loo_by_person(clusters, group, threshold, min_speech):
    """Тот же leave-one-file-out, но с разбивкой по людям: средняя цифра прячет,
    что свой голос узнаётся почти всегда, а редкий коллега — почти никогда."""
    cs = [c for c in clusters if c["speech_sec"] >= min_speech]
    res = defaultdict(lambda: defaultdict(int))
    for c in cs:
        gallery = defaultdict(list)
        for o in cs:
            if group[o["slug"]] != group[c["slug"]]:
                gallery[o["name"]].append(o["emb"])
        if c["name"] not in gallery:
            continue
        names = list(gallery)
        means = [np.mean(gallery[n], axis=0) for n in names]
        G = np.stack([m / np.linalg.norm(m) for m in means])
        scores = G @ c["emb"]
        k = int(np.argmax(scores))
        r = res[c["name"]]
        r["кластеров"] += 1
        if scores[k] < threshold:
            r["не узнан"] += 1
        elif names[k] == c["name"]:
            r["узнан"] += 1
        else:
            r["назван чужим"] += 1
    for name, r in res.items():
        r["записей"] = len({group[c["slug"]] for c in cs if c["name"] == name})
    return res


def fmt(a: np.ndarray) -> str:
    if a.size == 0:
        return "нет данных"
    return (f"n={a.size}  медиана {np.median(a):.3f}  "
            f"p05 {np.percentile(a, 5):.3f}  p95 {np.percentile(a, 95):.3f}  "
            f"[{a.min():.3f}…{a.max():.3f}]")


def main() -> int:
    if not (OUT / "labels.json").exists():
        print(f"нет {OUT/'labels.json'} — сначала разметь кластеры (label_server.py)")
        return 1
    clusters, durations, file_names = load()
    if len(clusters) < 4:
        print(f"размеченных кластеров всего {len(clusters)} — замерять нечего")
        return 1
    group = recording_groups(durations)

    lines = []
    def out(s=""):
        print(s)
        lines.append(s)

    by_name = defaultdict(set)
    for c in clusters:
        by_name[c["name"]].add(c["slug"])
    dup = {g for g in group.values() if list(group.values()).count(g) > 1}

    out("# Замер узнавания голоса между файлами\n")
    out(f"Размечено кластеров: **{len(clusters)}** "
        f"в {len({c['slug'] for c in clusters})} файлах.")
    out(f"Людей: **{len(by_name)}**; из них встречаются более чем в одном файле: "
        f"**{sum(1 for n, s in by_name.items() if len({group[x] for x in s}) > 1)}**.")
    if dup:
        out(f"\nСгруппированы как одна запись (совпала длительность): "
            f"{', '.join(sorted(file_names[s] for s in group if group[s] in dup))}. "
            "Пары внутри группы из кросс-файловой статистики исключены.")

    for tag, floor in (("все кластеры", 0.0), (f"речи ≥ {LONG_ENOUGH:.0f} c", LONG_ENOUGH)):
        ps = pairs(clusters, group, floor)
        pos = [s for s, same, *_ in ps if same]
        neg = [s for s, same, *_ in ps if not same]
        out(f"\n## Косинус между файлами — {tag}\n")
        out(f"- тот же человек:  {fmt(np.array(pos))}")
        out(f"- разные люди:     {fmt(np.array(neg))}")
        t_eer, v_eer = eer(pos, neg)
        if v_eer is not None:
            out(f"- **EER {v_eer*100:.1f}%** при пороге {t_eer:.3f}")
        for far in (0.01, 0.05):
            r = at_far(pos, neg, far)
            if r:
                out(f"- порог {r[0]:.3f} → чужих принято {r[1]*100:.1f}%, "
                    f"своих не узнано {r[2]*100:.1f}%")

        if floor == 0.0 and ps:
            out("\n  По типам канала (тот же человек / разные люди, медианы):\n")
            out("  | пара каналов | n свои | медиана свои | n чужие | медиана чужие |")
            out("  |---|---|---|---|---|")
            def med(a):
                return f"{np.median(a):.3f}" if a.size else "—"

            for pair in (("phone", "phone"), ("vks", "vks"), ("phone", "vks")):
                sel = [(sc, same) for sc, same, ca, cb in ps if {ca, cb} == set(pair)]
                same_s = np.array([sc for sc, same in sel if same])
                diff_s = np.array([sc for sc, same in sel if not same])
                out(f"  | {pair[0]}↔{pair[1]} | {same_s.size} | {med(same_s)} "
                    f"| {diff_s.size} | {med(diff_s)} |")

    out("\n## Насколько длинным должен быть кластер\n")
    out("Главный вывод замера обычно здесь: короткая реплика не опознаётся никаким порогом, "
        "и вопрос лишь в том, где проходит граница «хватит речи, чтобы называть имя».\n")
    out("| минимум речи в кластере | пар свои | медиана свои | минимум свои | "
        "пар чужие | максимум чужие | зазор |")
    out("|---|---|---|---|---|---|---|")
    for floor in (0, 10, 20, 30, 60, 120):
        ps = pairs(clusters, group, floor)
        pos = np.array([sc for sc, same, *_ in ps if same])
        neg = np.array([sc for sc, same, *_ in ps if not same])
        if not pos.size or not neg.size:
            out(f"| {floor} c | {pos.size} | — | — | {neg.size} | — | — |")
            continue
        gap = pos.min() - neg.max()
        out(f"| {floor} c | {pos.size} | {np.median(pos):.3f} | {pos.min():.3f} | "
            f"{neg.size} | {neg.max():.3f} | **{gap:+.3f}** |")
    out("\nЗазор — расстояние между худшим «своим» и лучшим «чужим». Положительный зазор "
        "значит, что порог, разделяющий их без ошибок, существует.")

    ths = [0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80]
    out("\n## Что было бы на практике (leave-one-file-out)\n")
    out("Галерея собирается из всех файлов, кроме проверяемого; кластеры проверяемого "
        "матчатся с ней. «Чужого приняли» и «перепутаны люди» — это неверное имя "
        "в транскрипте, худший вид ошибки.\n")
    for floor in (0.0, LONG_ENOUGH):
        st = loo(clusters, group, ths, floor)
        out(f"\n**{'Все кластеры' if not floor else f'Только кластеры с речью ≥ {floor:.0f} c'}**\n")
        out("| порог | верно названо | перепутаны люди | чужого приняли | свой не узнан "
            "| корректный отказ | неверных имён |")
        out("|---|---|---|---|---|---|---|")
        for t in ths:
            s = st[t]
            bad = s["перепутаны люди"] + s["чужого приняли за своего"]
            total = sum(s.values())
            out(f"| {t:.2f} | {s['верно названо']} | {s['перепутаны люди']} | "
                f"{s['чужого приняли за своего']} | {s['свой не узнан']} | "
                f"{s['корректный отказ']} | **{bad}/{total}** |")

    out("\n## По людям: кого узнаёт, а кого нет\n")
    out(f"Leave-one-file-out при пороге 0.70, только кластеры с речью ≥ {LONG_ENOUGH:.0f} c. "
        "Человек, встреченный в одной записи, при её проверке в галерее отсутствует — "
        "правильный ответ для него «не узнан», и такие строки здесь не показаны.\n")
    out("| человек | записей | кластеров | узнан | не узнан | назван чужим именем |")
    out("|---|---|---|---|---|---|")
    per = loo_by_person(clusters, group, 0.70, LONG_ENOUGH)
    for name, r in sorted(per.items(), key=lambda kv: (-kv[1]["записей"], -kv[1]["узнан"])):
        if r["записей"] < 2:
            continue
        out(f"| {name} | {r['записей']} | {r['кластеров']} | {r['узнан']} | "
            f"{r['не узнан']} | {r['назван чужим']} |")

    me = [c for c in clusters if c["name"].casefold() in ("я", "me", "ms")]
    if me:
        out(f"\n## Отдельно твой голос\n\nКластеров «я»: {len(me)} "
            f"в {len({c['slug'] for c in me})} файлах.")
        mp = [float(a["emb"] @ b["emb"]) for i, a in enumerate(me) for b in me[i+1:]
              if group[a["slug"]] != group[b["slug"]]]
        mn = [float(a["emb"] @ c["emb"]) for a in me for c in clusters
              if c["name"] != a["name"] and group[a["slug"]] != group[c["slug"]]]
        out(f"- я ↔ я между файлами:  {fmt(np.array(mp))}")
        out(f"- я ↔ кто угодно другой: {fmt(np.array(mn))}")

    (OUT / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\n(отчёт сохранён в {OUT/'report.md'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
