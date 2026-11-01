"""Узнавание голоса: чистая математика над эмбеддингами кластеров.

Два слоя, и это требование приёмки, а не стилистика:
  - слой 1, `match()` — один вектор против галереи. Ровно то, что считает
    `poc/spkid/analyze.py`; регрессионный тест сверяет их на данных замера;
  - слой 2, `identify()` — правила файла: фильтр по объёму речи (FR-8.9), конфликт
    «одно имя на двух кластерах» (FR-8.3), две полосы уверенности (§5 фичи).

Ни pyannote, ни файлов, ни путей: только numpy. Пороги здесь не назначены, а
измерены (ADR-016); менять их — через пере-вывод скриптами poc/spkid.
"""

from collections import defaultdict
from dataclasses import dataclass, replace
from typing import Optional

import numpy as np

# Косинус, начиная с которого имя ставится без пометки: на замере при 0.80 —
# 0 неверных имён из 53 длинных кластеров. Ниже, но выше выбранного порога — «Имя(?)».
CONFIDENT = 0.80
UNSURE_MARK = "(?)"

_EPS = 1e-6


def normalize(v) -> Optional[np.ndarray]:
    """Единичный вектор (float64) или None для нулевого: косинус с нулём не определён.

    pyannote добивает `centroids` нулевыми строками, когда спикеров в аннотации больше,
    чем кластеров, — такие кластеры сравнивать не с чем.
    """
    a = np.asarray(v, dtype=np.float64).reshape(-1)
    n = float(np.linalg.norm(a))
    if n < _EPS:
        return None
    return a / n


def build_gallery(samples: dict[str, list]) -> dict[str, np.ndarray]:
    """{имя: [сырые образцы]} → {имя: единичный центроид}.

    Каждый образец нормируется, берётся среднее, результат снова нормируется. Усреднение
    только здесь, а не при записи в базу: образцы с телефона и с ВКС различаются заметно
    (медианы 0.861 против 0.792), и усреднить их заранее значит потерять оба.
    """
    gallery: dict[str, np.ndarray] = {}
    for name, embs in samples.items():
        units = [u for u in (normalize(e) for e in embs) if u is not None]
        if not units:
            continue
        centroid = normalize(np.mean(units, axis=0))
        if centroid is not None:
            gallery[name] = centroid
    return gallery


def match(cluster_emb, gallery: dict[str, np.ndarray],
          threshold: float) -> tuple[Optional[str], float]:
    """Лучшее имя из галереи и его косинус, либо (None, score) если ниже порога.

    Никаких правил файла здесь нет — analyze.py их тоже не применяет, иначе
    таблицы замера не сойдутся. Пустая галерея или нулевой вектор → (None, 0.0).
    """
    unit = normalize(cluster_emb)
    if unit is None or not gallery:
        return None, 0.0
    best_name, best = None, -np.inf
    for name, centroid in gallery.items():
        score = float(centroid @ unit)
        if score > best:
            best, best_name = score, name
    return (best_name if best >= threshold else None), best


@dataclass(frozen=True)
class Identity:
    """Итог узнавания одного кластера."""
    name: Optional[str]     # имя из галереи; None — остаётся «Спикер N»
    score: float            # лучший косинус (0.0, если не сравнивали)
    sure: bool              # score ≥ CONFIDENT: имя без пометки

    @property
    def display(self) -> Optional[str]:
        """Как имя пишется в транскрипте: «Имя», «Имя(?)» или None."""
        if self.name is None:
            return None
        return self.name if self.sure else f"{self.name}{UNSURE_MARK}"


def identify(clusters: dict[str, tuple], gallery: dict[str, np.ndarray],
             threshold: float, min_speech: float) -> dict[str, Identity]:
    """Правила файла поверх `match()`.

    `clusters` — {метка: (эмбеддинг, секунд речи)}.
    - Кластер с речью < `min_speech` не сравнивается вовсе: в 11-секундной реплике
      нет сигнала о говорящем (худшая пара «тот же человек» на полной выборке 0.106,
      с отсечкой по 30 c — 0.489). Это не сомнение, а отсутствие данных, поэтому
      и пометки «(?)» он не получает.
    - Одно имя на двух кластерах: остаётся у того, чей косинус выше; второй — без
      имени (не второе-лучшее: человек не говорит двумя голосами одновременно).
    """
    result: dict[str, Identity] = {}
    for label, (emb, speech) in clusters.items():
        if speech < min_speech:
            result[label] = Identity(None, 0.0, False)
            continue
        name, score = match(emb, gallery, threshold)
        result[label] = Identity(name, score, score >= CONFIDENT)

    claims: dict[str, list[str]] = defaultdict(list)
    for label, ident in result.items():
        if ident.name is not None:
            claims[ident.name].append(label)
    for labels in claims.values():
        if len(labels) < 2:
            continue
        winner = max(labels, key=lambda lab: result[lab].score)
        for lab in labels:
            if lab != winner:
                result[lab] = replace(result[lab], name=None)
    return result
