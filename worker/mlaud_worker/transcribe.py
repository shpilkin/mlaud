"""Обёртка над gigaam-mlx: загрузка модели один раз, транскрипция файла в сегменты.

Подменяет загрузчик аудио gigaam_mlx на наш ffmpeg-free (afconvert + soxr).
"""

import importlib
from typing import Optional

# Подсунуть submodule, а не одноимённую re-exported функцию из пакета.
_T = importlib.import_module("gigaam_mlx.transcribe")

from .audio import load_audio


class Transcriber:
    """Ленивая загрузка модели; модель грузится при первом transcribe()."""

    def __init__(self, model_type: str = "rnnt"):
        self.model_type = model_type
        self._model = None
        self._tokenizer = None

    def _ensure_loaded(self) -> None:
        if self._model is None:
            from gigaam_mlx import load_model

            from .mlx_cache import limit_cache

            limit_cache()
            self._model, self._tokenizer = load_model(model_type=self.model_type)
            _T.load_audio = load_audio  # ffmpeg-free декодирование

    def transcribe(self, path: str) -> list[dict]:
        """Вернуть список сегментов: [{'start': float, 'end': float, 'text': str}, ...]."""
        self._ensure_loaded()
        return _T.transcribe_file(
            str(path),
            model=self._model,
            tokenizer=self._tokenizer,
            model_type=self.model_type,
            verbose=False,
        )

    # Кадр энкодера = hop 160 / 16000 * 4x субсэмплинг = 40 мс.
    FRAME_SEC = 0.04

    def transcribe_words(self, path: str) -> list[dict]:
        """Транскрипция с тайм-кодами на уровне СЛОВ: [{'start','end','text'}, ...].

        Тот же greedy-декод, что и в gigaam (текст идентичен), но с отслеживанием
        кадра эмиссии каждого токена. Нужен для точной диаризации (резать речь по
        границам спикеров, а не по 20-сек чанкам).
        """
        self._ensure_loaded()
        import mlx.core as mx
        import numpy as np
        from gigaam_mlx.audio import compute_mel, split_audio

        audio = load_audio(path)
        words: list[dict] = []
        for chunk in split_audio(audio):
            ca = audio[chunk["start_sample"]:chunk["end_sample"]]
            mel = compute_mel(ca)
            encoded, seq_len = self._model.encode(mx.array(mel[np.newaxis]))
            mx.eval(encoded)
            toks = self._decode_with_frames(encoded, seq_len)
            words.extend(self._tokens_to_words(toks, chunk["start_sec"]))
        return words

    def _decode_with_frames(self, encoded, seq_len) -> list[tuple]:
        """Greedy-декод, возвращающий [(token_id, frame_index), ...]."""
        import mlx.core as mx

        m = self._model
        if m.model_type == "ctc":
            log_probs = m.head(encoded)
            labels = mx.argmax(log_probs[0, :seq_len, :], axis=-1)
            mx.eval(labels)
            blank = m.num_classes - 1
            out, prev = [], blank
            for i, tok in enumerate(labels.tolist()):
                if tok != blank and tok != prev:
                    out.append((tok, i))
                prev = tok
            return out

        # RNNT
        enc = encoded[0]
        blank = m.decoder.blank_id
        out: list[tuple] = []
        state = None
        last = None
        for t in range(seq_len):
            f = enc[:, t:t + 1].T
            f = mx.expand_dims(f, axis=0) if f.ndim == 2 else f
            symbols = 0
            while symbols < 10:
                g, new_state = m.decoder.predict(last, state)
                logits = m.joint(f, g)
                k = mx.argmax(logits[0, 0, 0, :]).item()
                if k == blank:
                    break
                out.append((int(k), t))
                state = new_state
                last = mx.array([[k]])
                symbols += 1
        return out

    def _tokens_to_words(self, toks: list[tuple], offset_sec: float) -> list[dict]:
        """Сгруппировать (token, frame) в слова по маркеру SentencePiece '▁'."""
        words: list[dict] = []
        cur = None
        for tok, frame in toks:
            piece = self._tokenizer.id_to_piece(tok)
            t = offset_sec + frame * self.FRAME_SEC
            if piece.startswith("▁") or cur is None:
                if cur is not None:
                    words.append(cur)
                cur = {"start": t, "end": t + self.FRAME_SEC,
                       "text": piece.replace("▁", " ").strip()}
            else:
                cur["text"] += piece
                cur["end"] = t + self.FRAME_SEC
        if cur is not None and cur["text"]:
            words.append(cur)
        return [w for w in words if w["text"]]


def transcribe_file(path: str, transcriber: Optional[Transcriber] = None,
                    model_type: str = "rnnt") -> list[dict]:
    """Удобная функция: транскрибировать один файл (создаёт Transcriber при отсутствии)."""
    t = transcriber or Transcriber(model_type=model_type)
    return t.transcribe(path)
