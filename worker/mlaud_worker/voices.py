"""База голосов (~/ASR/voices) и CLI enrollment — v1, без окна.

Раскладка (§3 задачи):
  index.json          {"version": 1, "people": {"<имя>": {"created", "samples": [id, …]}}}
  samples/<id>.npy    (256,) float32 — сырой центроид кластера, как отдал pyannote
  samples/<id>.json   {"person", "source_file", "label", "speech_sec", "channel", "added"}

Образцы хранятся по отдельности и усредняются только при матчинге
(spkid.build_gallery). Это биометрия: каталог локальный, не в iCloud, права 0700,
удаление человека удаляет и .npy, и .json.

    python -m mlaud_worker.voices enroll <audio> <кластер> "<Имя>" [--channel phone|vks|other]
    python -m mlaud_worker.voices show <audio>
    python -m mlaud_worker.voices list
    python -m mlaud_worker.voices remove --sample <id> | --person "<Имя>"

<кластер> — «Спикер N» из транскрипта (или просто N) либо сырая метка SPEAKER_NN.
"""

import argparse
import json
import os
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import numpy as np

from . import channels, spkid

CHANNELS = ("phone", "vks", "other")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class VoiceStore:
    VERSION = 1

    def __init__(self, root):
        self.root = Path(root)
        self.index_path = self.root / "index.json"
        self.samples_dir = self.root / "samples"

    # --- индекс ---

    def _load(self) -> dict:
        if not self.index_path.exists():
            return {"version": self.VERSION, "people": {}}
        data = json.loads(self.index_path.read_text(encoding="utf-8"))
        data.setdefault("version", self.VERSION)
        data.setdefault("people", {})
        return data

    def _ensure_dirs(self) -> None:
        # mode= действует только на последний сегмент, поэтому корень — отдельно:
        # иначе он получил бы 755 как «родитель» samples/.
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.samples_dir.mkdir(exist_ok=True, mode=0o700)

    def _save(self, index: dict) -> None:
        self._ensure_dirs()
        tmp = self.index_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(index, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, self.index_path)

    def people(self) -> dict:
        """{имя: {"created", "samples": [id, …]}}."""
        return self._load()["people"]

    def samples(self, person: Optional[str] = None) -> list[dict]:
        """Метаданные образцов (с полем "id"); чей-то одного или всех."""
        people = self.people()
        names = [person] if person is not None else list(people)
        out = []
        for name in names:
            for sid in people.get(name, {}).get("samples", []):
                meta_path = self.samples_dir / f"{sid}.json"
                if not meta_path.exists():
                    continue
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
                meta["id"] = sid
                out.append(meta)
        return out

    # --- образцы ---

    def add(self, person: str, emb, *, source_file: str, label: str,
            speech_sec: float, channel: str = "other") -> str:
        """Положить сырой центроид под именем. Возвращает id образца."""
        person = self._valid_name(person)
        if channel not in CHANNELS:
            raise ValueError(f"канал {channel!r}: ожидается один из {CHANNELS}")
        vec = np.asarray(emb, dtype=np.float32).reshape(-1)
        if spkid.normalize(vec) is None:
            raise ValueError("нулевой эмбеддинг: это добивка pyannote, образца из неё не выйдет")

        index = self._load()
        entry = index["people"].setdefault(person, {"created": _now(), "samples": []})
        sid = uuid.uuid4().hex[:12]
        self._ensure_dirs()
        np.save(self.samples_dir / f"{sid}.npy", vec)
        meta = {
            "person": person, "source_file": source_file, "label": label,
            "speech_sec": float(speech_sec), "channel": channel, "added": _now(),
        }
        (self.samples_dir / f"{sid}.json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        entry["samples"].append(sid)
        self._save(index)
        return sid

    @staticmethod
    def _valid_name(person: str) -> str:
        person = " ".join(person.split())
        if not person:
            raise ValueError("пустое имя")
        # По «имя: » разбирается префикс в транскрипте при переподписи.
        if ":" in person:
            raise ValueError("двоеточие в имени недопустимо")
        return person

    def rename(self, old: str, new: str) -> int:
        """Переименовать человека (индекс и метаданные образцов). Возвращает число образцов."""
        new = self._valid_name(new)
        index = self._load()
        if old not in index["people"]:
            raise KeyError(old)
        if new != old and new in index["people"]:
            raise ValueError(f"«{new}» уже есть в базе")
        entry = index["people"].pop(old)
        index["people"][new] = entry
        for sid in entry["samples"]:
            meta_path = self.samples_dir / f"{sid}.json"
            if meta_path.exists():
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
                meta["person"] = new
                meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2),
                                     encoding="utf-8")
        self._save(index)
        return len(entry["samples"])

    def _unlink_sample(self, sid: str) -> None:
        for suffix in (".npy", ".json"):
            p = self.samples_dir / f"{sid}{suffix}"
            if p.exists():
                p.unlink()

    def remove_sample(self, sid: str) -> Optional[str]:
        """Удалить один образец (файлы и запись). Возвращает имя владельца или None."""
        index = self._load()
        for name, entry in index["people"].items():
            if sid in entry["samples"]:
                entry["samples"].remove(sid)
                self._unlink_sample(sid)
                self._save(index)
                return name
        return None

    def remove_person(self, person: str) -> int:
        """Удалить человека со всеми образцами. Возвращает число удалённых образцов."""
        index = self._load()
        entry = index["people"].pop(person, None)
        if entry is None:
            raise KeyError(person)
        for sid in entry["samples"]:
            self._unlink_sample(sid)
        self._save(index)
        return len(entry["samples"])

    def gallery(self) -> dict[str, np.ndarray]:
        """{имя: единичный центроид} для матчинга; образцы без .npy пропускаются."""
        samples: dict[str, list] = {}
        for name, entry in self.people().items():
            vecs = []
            for sid in entry["samples"]:
                p = self.samples_dir / f"{sid}.npy"
                if p.exists():
                    vecs.append(np.load(p))
            if vecs:
                samples[name] = vecs
        return spkid.build_gallery(samples)


# --- CLI ---


class Context:
    """Что нужно командам: конфиг, база, модели и Telegram (подменяются в тестах)."""

    def __init__(self, cfg, store: VoiceStore, diarizer=None, notifier=None, transcriber=None):
        self.cfg, self.store, self.diarizer, self.notifier = cfg, store, diarizer, notifier
        self.transcriber = transcriber


def _resolve_cluster(arg: str, turns: list[dict]) -> Optional[str]:
    """«Спикер N» / N / SPEAKER_NN → сырая метка pyannote, либо None.

    В транскрипте видно «Спикер N» (нумерация по первому появлению), а pyannote
    нумерует SPEAKER_NN иначе — принимаем обе формы.
    """
    from .diarize import relabel

    return _match_label(arg, relabel(turns))


def _match_label(arg: str, mapping: dict) -> Optional[str]:
    if arg in mapping:
        return arg
    key = " ".join(arg.split()).casefold()
    if key.isdigit():
        key = f"спикер {key}"
    for raw, display in mapping.items():
        if display.casefold() == key:
            return raw
    return None


def _mmss(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 60:02d}:{s % 60:02d}"


def _cluster_rows(turns: list[dict], centroids: dict, gallery: dict, cfg) -> list[str]:
    """Таблица кластеров файла: метка, речь, первая реплика, текущий матч."""
    from .diarize import relabel, speech_seconds

    mapping = relabel(turns)
    speech = speech_seconds(turns)
    first: dict[str, float] = {}
    for t in turns:
        first[t["speaker"]] = min(first.get(t["speaker"], t["start"]), t["start"])
    clusters = {raw: (centroids[raw], speech.get(raw, 0.0))
                for raw in mapping if raw in centroids}
    idents = spkid.identify(clusters, gallery, cfg.identify_threshold, cfg.identify_min_speech)

    rows = [f"{'метка':<10} {'pyannote':<11} {'речь':>7}  {'первая':>6}  узнан как"]
    for raw, display in mapping.items():
        sec = speech.get(raw, 0.0)
        ident = idents.get(raw)
        if raw not in centroids:
            status = "— (нет эмбеддинга)"
        elif sec < cfg.identify_min_speech:
            status = f"— (меньше {cfg.identify_min_speech:.0f} c речи)"
        elif ident.name is not None:
            status = f"{ident.display}  {ident.score:.3f}"
        elif not gallery:
            status = "— (база пуста)"
        else:
            status = f"— (лучший {ident.score:.3f} < {cfg.identify_threshold:.2f})"
        rows.append(f"{display:<10} {raw:<11} {sec:>5.0f} c  {_mmss(first.get(raw, 0.0)):>6}  {status}")
    return rows


def _diarize(audio: Path, ctx: Context):
    diarizer = ctx.diarizer
    if diarizer is None:
        from .diarize import Diarizer
        diarizer = Diarizer(hf_token=ctx.cfg.hf_token or None,
                            device=ctx.cfg.diarize_device or None)
    return diarizer.diarize(str(audio), num_speakers=ctx.cfg.num_speakers or None)


def cmd_show(args, ctx: Context) -> int:
    audio = Path(args.audio)
    if not audio.is_file():
        print(f"нет файла: {audio}", file=sys.stderr)
        return 2
    turns, centroids = _diarize(audio, ctx)
    print("\n".join(_cluster_rows(turns, centroids, ctx.store.gallery(), ctx.cfg)))
    return 0


def cmd_enroll(args, ctx: Context) -> int:
    from .diarize import relabel, speech_seconds

    cfg, store = ctx.cfg, ctx.store
    audio = Path(args.audio)
    if not audio.is_file():
        print(f"нет файла: {audio}", file=sys.stderr)
        return 2
    turns, centroids = _diarize(audio, ctx)
    raw = _resolve_cluster(args.cluster, turns)
    if raw is None:
        print(f"кластер «{args.cluster}» в {audio.name} не найден. Кластеры файла:",
              file=sys.stderr)
        print("\n".join(_cluster_rows(turns, centroids, store.gallery(), cfg)), file=sys.stderr)
        return 2
    display = relabel(turns)[raw]
    speech = speech_seconds(turns).get(raw, 0.0)
    if speech < cfg.identify_min_speech:
        print(f"отказ: у «{display}» ({raw}) всего {speech:.0f} c речи, для образца нужно "
              f"≥ {cfg.identify_min_speech:.0f} c (FR-8.9) — короткий кластер испортит отпечаток",
              file=sys.stderr)
        return 1
    emb = centroids.get(raw)
    if emb is None or spkid.normalize(emb) is None:
        print(f"отказ: у «{display}» ({raw}) нет эмбеддинга (добивка pyannote)", file=sys.stderr)
        return 1
    try:
        sid = store.add(args.name, emb, source_file=audio.name, label=raw,
                        speech_sec=round(speech, 1), channel=args.channel)
    except ValueError as e:
        print(f"отказ: {e}", file=sys.stderr)
        return 1
    print(f"образец {sid}: «{args.name.strip()}» ← {display} ({raw}), {speech:.0f} c речи, "
          f"канал {args.channel}, из {audio.name}")
    return 0


def _period_of(audio: Path) -> str:
    """Месяц архива: папка YYYY-MM, в которой лежит файл, иначе по имени/времени файла."""
    from .pipeline import derive_period

    parent = audio.parent.name
    if re.fullmatch(r"\d{4}-\d{2}", parent):
        return parent
    return derive_period(audio)


def cmd_prepare(args, ctx: Context) -> int:
    """Старая запись → транскрипт заново с именами из базы + сайдкар для разметки.

    Ровно то, что делает конвейер, но без доставки и архивации: файл остаётся на месте,
    в Telegram ничего не уходит. Транскрипт в папке результатов перезаписывается —
    иначе подписи в сайдкаре и в файле разойдутся.
    """
    from . import speakers as spk
    from .output import write_outputs
    from .pipeline import analyze

    cfg = ctx.cfg
    transcriber, diarizer = ctx.transcriber, ctx.diarizer
    gallery = ctx.store.gallery()
    code = 0
    for arg in args.audio:
        audio = Path(arg)
        if not audio.is_file():
            print(f"нет файла: {audio}", file=sys.stderr)
            code = 2
            continue
        if channels.find_sidecar(audio) is not None:
            # Звонок подписан по каналам (ADR-026): диаризация заменила бы «Я/Собеседник» на «Спикер N».
            print(f"{audio.name}: запись звонка с сайдкаром каналов — переразметка голосов "
                  f"не применяется", file=sys.stderr)
            code = 2
            continue
        if transcriber is None:
            from .transcribe import Transcriber
            transcriber = Transcriber(model_type=cfg.model_type)
        if diarizer is None:
            from .diarize import Diarizer
            diarizer = Diarizer(hf_token=cfg.hf_token or None, device=cfg.diarize_device or None)
        base = audio.stem
        # Транскрипт кладём туда, где он уже лежит: месяц старого прогона мог считаться
        # от mtime, а он с тех пор поменялся (перенос, iCloud). Одно имя в двух месяцах —
        # берём месяц самого аудио, а не первый по алфавиту.
        own = _period_of(audio)
        existing = sorted(cfg.output.glob(f"*/{base}.txt"))
        same = [p for p in existing if p.parent.name == own]
        if same or not existing:
            period = own
        elif len(existing) == 1:
            period = existing[0].parent.name
        else:
            months = ", ".join(p.parent.name for p in existing)
            print(f"транскрипт «{base}» есть в месяцах {months}, а в месяце аудио {own} — нет: "
                  f"не знаю, какой перезаписывать", file=sys.stderr)
            code = 2
            continue
        result = analyze(audio, cfg, transcriber, diarizer, gallery)
        outputs = write_outputs(result.segments, cfg.output / period, base)
        sidecar = spk.write(cfg, audio, period=period, base=base, outputs=outputs,
                            turns=result.turns, centroids=result.centroids,
                            names=result.names, idents=result.idents,
                            segments=result.segments)
        print(f"готово: {base} — {len(result.segments)} реплик, "
              f"к разметке: {spk.pending_count(sidecar)}")
    return code


# --- пересчёт подсказок по текущей базе ---


def rematch_sidecars(cfg, store: VoiceStore, paths=None) -> int:
    """Обновить `match` в сайдкарах по текущей базе; `assigned`/`written` не трогаются.

    Так разметка одного файла сразу даёт подсказки в остальных (у Otter это «Rematch»).
    Дёшево: векторы лежат в сайдкарах, аудио не нужно. Возвращает число изменённых сайдкаров.
    """
    from . import speakers as spk

    gallery = store.gallery()
    changed = 0
    for path in (paths or spk.list_sidecars(cfg)):
        sidecar = spk.load(path)
        taken = {c["assigned"] for c in sidecar["clusters"] if c.get("assigned")}
        clusters = {c["label"]: (np.asarray(c["embedding"], dtype=np.float32), c["speech_sec"])
                    for c in sidecar["clusters"]
                    if c.get("embedding") and not c.get("assigned")}
        idents = spkid.identify(clusters, gallery, sidecar["threshold"], sidecar["min_speech"])
        touched = False
        for c in sidecar["clusters"]:
            ident = idents.get(c["label"])
            if ident is None:
                continue
            new = None
            # Имя, уже отданное другому кластеру этого файла, не предлагаем: один человек
            # не говорит двумя голосами.
            if ident.name is not None and ident.name not in taken:
                new = {"name": ident.name, "score": round(float(ident.score), 4),
                       "sure": bool(ident.sure)}
            if new != c.get("match"):
                c["match"] = new
                touched = True
        if touched:
            spk.save(path, sidecar)
            spk.relabel_transcript(path)
            changed += 1
    return changed


def cmd_rematch(args, ctx: Context) -> int:
    from . import speakers as spk

    paths = [spk.resolve_path(a) for a in args.sidecar] or None
    n = rematch_sidecars(ctx.cfg, ctx.store, paths)
    print(f"подсказки пересчитаны, изменено записей: {n}")
    return 0


def cmd_import_eval(args, ctx: Context) -> int:
    """Перенести разметку замера (poc/spkid, ~/ASR/spkid-eval) в базу голосов.

    Те же правила, что у analyze.py: смеси и безымянные не берём, имена сводим без учёта
    регистра, одна встреча в двух форматах (совпала длительность) — один файл. Плюс FR-8.9:
    кластер короче порога речи в базу не идёт. Повторный запуск ничего не дублирует.
    """
    from collections import Counter

    root = Path(args.eval_dir).expanduser()
    labels_path, data = root / "labels.json", root / "data"
    if not labels_path.exists() or not data.is_dir():
        print(f"нет разметки замера: {labels_path} / {data}", file=sys.stderr)
        return 2
    labels = json.loads(labels_path.read_text(encoding="utf-8"))
    marks = labels.get("speakers", {})
    channels = labels.get("channels", {})
    recs = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(data.glob("*.json"))]
    durations = {r["slug"]: float(r.get("duration") or 0.0) for r in recs}

    # Та же встреча в другом формате — не второй набор образцов.
    group: dict[str, str] = {}
    for slug, dur in sorted(durations.items(), key=lambda kv: -kv[1]):
        for other, gid in group.items():
            if abs(durations[other] - dur) <= 1.0:
                group[slug] = gid
                break
        else:
            group[slug] = slug

    existing = {(s["source_file"], s["label"]) for s in ctx.store.samples()}
    # «я» и «Я» — один человек; берём самое частое написание, при равенстве — первое по сортировке.
    spellings: dict[str, Counter] = {}
    for mark in marks.values():
        name = (mark.get("name") or "").strip()
        if name:
            spellings.setdefault(name.casefold(), Counter())[name] += 1
    canon = {key: sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
             for key, c in spellings.items()}
    added: Counter = Counter()
    skipped = Counter()
    for rec in recs:
        slug = rec["slug"]
        if group[slug] != slug:
            skipped["дубль встречи"] += 1
            continue
        npy = data / f"{slug}.npy"
        if not npy.exists():
            skipped["нет .npy"] += 1
            continue
        cents = np.load(npy)
        channel = channels.get(slug) or "other"
        if channel not in CHANNELS:
            channel = "other"
        for sp in rec.get("speakers", []):
            mark = marks.get(f"{slug}|{sp['label']}", {})
            name = (mark.get("name") or "").strip()
            if sp.get("padded") or mark.get("mixed") or not name:
                continue
            name = canon.get(name.casefold(), name)
            if sp["speech_sec"] < ctx.cfg.identify_min_speech:
                skipped["короче порога"] += 1
                continue
            if (rec["name"], sp["label"]) in existing:
                skipped["уже в базе"] += 1
                continue
            try:
                ctx.store.add(name, cents[sp["index"]], source_file=rec["name"],
                              label=sp["label"], speech_sec=sp["speech_sec"], channel=channel)
            except ValueError as e:
                skipped[f"отказ: {e}"] += 1
                continue
            added[name] += 1
    for name, n in sorted(added.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {name}: +{n}")
    print(f"добавлено образцов: {sum(added.values())} у {len(added)} чел.; "
          + ", ".join(f"{k}: {v}" for k, v in skipped.items()))
    if sum(added.values()):
        n = rematch_sidecars(ctx.cfg, ctx.store)
        print(f"подсказки пересчитаны, изменено записей: {n}")
    return 0


# --- команды поверх сайдкара записи (окно «Голоса») ---


def _load_sidecar(arg):
    from . import speakers as spk

    path = spk.resolve_path(arg)
    if not path.exists():
        print(f"нет сайдкара: {path}", file=sys.stderr)
        return None, None
    return path, spk.load(path)


def _find_cluster(sidecar: dict, arg: str) -> Optional[dict]:
    mapping = {c["label"]: c["display"] for c in sidecar["clusters"]}
    raw = _match_label(arg, mapping)
    return next((c for c in sidecar["clusters"] if c["label"] == raw), None) if raw else None


def cmd_assign(args, ctx: Context) -> int:
    from . import speakers as spk

    path, sidecar = _load_sidecar(args.sidecar)
    if sidecar is None:
        return 2
    c = _find_cluster(sidecar, args.cluster)
    if c is None:
        known = ", ".join(f"{x['display']} ({x['label']})" for x in sidecar["clusters"])
        print(f"кластер «{args.cluster}» не найден; есть: {known}", file=sys.stderr)
        return 2
    if args.name:
        try:
            name = VoiceStore._valid_name(args.name)
        except ValueError as e:
            print(f"отказ: {e}", file=sys.stderr)
            return 1
        # Короткий кластер (FR-8.9) или добивка без вектора: имя ставится только в
        # транскрипт, отпечаток в базу не идёт — из такой речи его не снять.
        enroll = c["speech_sec"] >= sidecar["min_speech"] and bool(c.get("embedding"))
        if enroll:
            try:
                sid = ctx.store.add(name, np.asarray(c["embedding"], dtype=np.float32),
                                    source_file=sidecar["source"], label=c["label"],
                                    speech_sec=c["speech_sec"], channel=args.channel)
            except ValueError as e:
                print(f"отказ: {e}", file=sys.stderr)
                return 1
            print(f"образец {sid}: «{name}» ← {c['display']} ({c['label']}) из {sidecar['source']}")
        else:
            print(f"«{name}» ← {c['display']}: только в транскрипт, в базу не добавлен "
                  f"({c['speech_sec']:.0f} c речи, для отпечатка нужно ≥ {sidecar['min_speech']:.0f} c)")
        c["assigned"] = name
        c["dismissed"] = False
        c["mixed"] = False
        c["rejected"] = [r for r in c.get("rejected", []) if r != name]
        spk.save(path, sidecar)
        if enroll:
            # База изменилась — остальные записи получают подсказки по новому голосу.
            rematch_sidecars(ctx.cfg, ctx.store)
            sidecar = spk.load(path)
            c = _find_cluster(sidecar, args.cluster)
    elif args.none:
        c["assigned"] = None
        c["dismissed"] = True
        c["mixed"] = False
        print(f"{c['display']}: оставлен без имени")
    elif args.mixed:
        c["assigned"] = None
        c["dismissed"] = True
        c["mixed"] = True
        print(f"{c['display']}: несколько голосов, в базу не идёт")
    elif args.delete:
        c["assigned"] = None
        c["dismissed"] = True
        c["hidden"] = True
        print(f"{c['display']}: убран из списка")
    elif args.restore:
        c["dismissed"] = False
        c["mixed"] = False
        c["hidden"] = False
        print(f"{c['display']}: снова к разметке")
    else:
        m = c.get("match")
        if m and m.get("name") and m["name"] not in c.setdefault("rejected", []):
            c["rejected"].append(m["name"])
        c["assigned"] = None
        c["dismissed"] = False
        print(f"{c['display']}: имя снято")
    spk.save(path, sidecar)
    # Имя в транскрипте появляется сразу: иначе окно и файл на диске расходятся,
    # и человек не понимает, что ещё надо нажать.
    res = spk.relabel_transcript(path)
    if res["changed"]:
        print(f"транскрипт переподписан: строк {res['changed']}")
    print(f"к разметке: {spk.pending_count(sidecar)}")
    return 0


def cmd_forget(args, ctx: Context) -> int:
    from . import speakers as spk

    path, sidecar = _load_sidecar(args.sidecar)
    if sidecar is None:
        return 2
    removed = spk.forget(path)
    print(f"убрано из разметки: {sidecar['base']} ({removed})")
    return 0


def cmd_relabel(args, ctx: Context) -> int:
    from . import speakers as spk

    path, sidecar = _load_sidecar(args.sidecar)
    if sidecar is None:
        return 2
    res = spk.relabel_transcript(path)
    if res["changed"]:
        print(f"переподписано строк: {res['changed']} в {', '.join(res['files'])}")
    else:
        print("транскрипт уже с текущими именами")
    return 0


def cmd_resend(args, ctx: Context) -> int:
    from .logutil import redact

    path, sidecar = _load_sidecar(args.sidecar)
    if sidecar is None:
        return 2
    txt = Path(sidecar["txt"])
    if not txt.exists():
        print(f"нет транскрипта: {txt}", file=sys.stderr)
        return 1
    notifier = ctx.notifier
    if notifier is None:
        from .__main__ import build_notifier
        notifier = build_notifier()
    if notifier is None:
        print("Telegram не настроен: нет MLAUD_TG_TOKEN / MLAUD_TG_CHAT_ID", file=sys.stderr)
        return 1
    try:
        notifier.send_document(txt, caption=sidecar["base"])
    except Exception as e:  # noqa: BLE001
        print(f"не отправлено: {redact(str(e))}", file=sys.stderr)
        return 1
    print(f"отправлено: {txt.name}")
    return 0


def cmd_rename(args, ctx: Context) -> int:
    from . import speakers as spk

    try:
        n = ctx.store.rename(args.old, args.new)
    except KeyError:
        print(f"человека «{args.old}» в базе нет", file=sys.stderr)
        return 1
    except ValueError as e:
        print(f"отказ: {e}", file=sys.stderr)
        return 1
    new = VoiceStore._valid_name(args.new)
    touched = 0
    for path in spk.list_sidecars(ctx.cfg):
        sidecar = spk.load(path)
        changed = False
        for c in sidecar["clusters"]:
            if c.get("assigned") == args.old:
                c["assigned"], changed = new, True
            if c.get("match") and c["match"].get("name") == args.old:
                c["match"]["name"], changed = new, True
            if args.old in c.get("rejected", []):
                c["rejected"] = [new if r == args.old else r for r in c["rejected"]]
                changed = True
        if changed:
            spk.save(path, sidecar)
            spk.relabel_transcript(path)
            touched += 1
    print(f"«{args.old}» → «{new}»: {n} образц., записей затронуто: {touched}")
    rematch_sidecars(ctx.cfg, ctx.store)
    return 0


def cmd_list(args, ctx: Context) -> int:
    store = ctx.store
    people = store.people()
    if getattr(args, "json", False):
        payload = {"root": str(store.root), "people": [
            {"name": name, "created": entry.get("created", ""), "samples": store.samples(name)}
            for name, entry in sorted(people.items())
        ]}
        print(json.dumps(payload, ensure_ascii=False))
        return 0
    if not people:
        print(f"база голосов пуста ({store.root})")
        return 0
    for name, entry in sorted(people.items()):
        samples = store.samples(name)
        print(f"{name}: {len(samples)} образц., с {entry.get('created', '?')[:10]}")
        for s in samples:
            print(f"    {s['id']}  {s['speech_sec']:>5.0f} c  {s['channel']:<5}  "
                  f"{s['label']}  {s['source_file']}  ({s['added'][:10]})")
    return 0


def cmd_remove(args, ctx: Context) -> int:
    store = ctx.store
    if args.sample:
        owner = store.remove_sample(args.sample)
        if owner is None:
            print(f"образца {args.sample} нет", file=sys.stderr)
            return 1
        print(f"удалён образец {args.sample} ({owner})")
        rematch_sidecars(ctx.cfg, store)
        return 0
    try:
        n = store.remove_person(args.person)
    except KeyError:
        print(f"человека «{args.person}» в базе нет", file=sys.stderr)
        return 1
    print(f"удалён «{args.person}» и {n} образц.")
    rematch_sidecars(ctx.cfg, store)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="python -m mlaud_worker.voices",
                                description="База голосов для узнавания спикеров (FR-8).")
    sub = p.add_subparsers(dest="command", required=True)

    e = sub.add_parser("enroll", help="положить голос кластера из аудио в базу под именем")
    e.add_argument("audio")
    e.add_argument("cluster", help="«Спикер N» из транскрипта, N или SPEAKER_NN")
    e.add_argument("name")
    e.add_argument("--channel", choices=CHANNELS, default="other",
                   help="откуда запись: телефон, ВКС, другое (по умолчанию other)")
    e.set_defaults(func=cmd_enroll)

    s = sub.add_parser("show", help="кластеры файла и кого база в них узнаёт")
    s.add_argument("audio")
    s.set_defaults(func=cmd_show)

    pr = sub.add_parser("prepare", help="подготовить старую запись к разметке: транскрипт "
                                         "заново + сайдкар, без доставки")
    pr.add_argument("audio", nargs="+", help="аудио из архива (~/ASR/Processed/AllRecords/…)")
    pr.set_defaults(func=cmd_prepare)

    a = sub.add_parser("assign", help="разметить кластер по сайдкару записи (без диаризации)")
    a.add_argument("sidecar", help="speakers.json или каталог записи")
    a.add_argument("cluster")
    g = a.add_mutually_exclusive_group(required=True)
    g.add_argument("--name", metavar="ИМЯ", help="это он: положить вектор в базу под именем")
    g.add_argument("--none", action="store_true", help="оставить без имени")
    g.add_argument("--mixed", action="store_true", help="в кластере несколько голосов")
    g.add_argument("--delete", action="store_true", help="убрать кластер из списка (корзина)")
    g.add_argument("--restore", action="store_true", help="вернуть скрытый кластер к разметке")
    g.add_argument("--reject", action="store_true", help="автоузнавание неверно: снять имя")
    a.add_argument("--channel", choices=CHANNELS, default="other")
    a.set_defaults(func=cmd_assign)

    rm2 = sub.add_parser("rematch", help="пересчитать подсказки в сайдкарах по текущей базе")
    rm2.add_argument("sidecar", nargs="*", help="по умолчанию — все записи")
    rm2.set_defaults(func=cmd_rematch)

    ie = sub.add_parser("import-eval", help="перенести разметку замера (poc/spkid) в базу голосов")
    ie.add_argument("eval_dir", nargs="?", default="~/ASR/spkid-eval")
    ie.set_defaults(func=cmd_import_eval)

    fg = sub.add_parser("forget", help="убрать запись из разметки: удалить сайдкар, клипы, векторы")
    fg.add_argument("sidecar")
    fg.set_defaults(func=cmd_forget)

    r = sub.add_parser("relabel", help="переписать .txt/.srt текущими именами кластеров")
    r.add_argument("sidecar")
    r.set_defaults(func=cmd_relabel)

    rs = sub.add_parser("resend", help="отправить транскрипт записи в Telegram заново")
    rs.add_argument("sidecar")
    rs.set_defaults(func=cmd_resend)

    rn = sub.add_parser("rename", help="переименовать человека в базе и сайдкарах")
    rn.add_argument("old")
    rn.add_argument("new")
    rn.set_defaults(func=cmd_rename)

    ls = sub.add_parser("list", help="кто в базе")
    ls.add_argument("--json", action="store_true", help="машиночитаемо, для приложения")
    ls.set_defaults(func=cmd_list)

    rm = sub.add_parser("remove", help="удалить образец или человека целиком")
    g = rm.add_mutually_exclusive_group(required=True)
    g.add_argument("--sample", metavar="ID")
    g.add_argument("--person", metavar="ИМЯ")
    rm.set_defaults(func=cmd_remove)
    return p


def main(argv=None, cfg=None, diarizer=None, notifier=None, transcriber=None) -> int:
    args = build_parser().parse_args(argv)
    if cfg is None:
        from .__main__ import build_config, load_dotenv
        load_dotenv()
        cfg = build_config()
    ctx = Context(cfg, VoiceStore(cfg.voices_dir), diarizer, notifier, transcriber)
    return args.func(args, ctx)


if __name__ == "__main__":
    raise SystemExit(main())
