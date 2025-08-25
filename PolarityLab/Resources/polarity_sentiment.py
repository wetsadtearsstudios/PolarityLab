# ==== PL PATCH: final-relay guard (python-only, normalize finish relay) ====
import builtins as _pl_builtins, json as _pl_json, sys as _pl_sys


def _PL_normalize_filter(msg):
    import json

    if isinstance(msg, dict) and "filter" not in msg and msg.get("filt") is not None:
        try:
            v = msg.get("filt")
            msg["filter"] = json.loads(v) if isinstance(v, str) else v
        except Exception:
            pass
    return msg


# Guard so the UI sees "final" exactly once, with a stable shape.
_PL_FINAL_SENT = False
_PL_ORIG_PRINT = _pl_builtins.print


def _pl_is_json_obj(txt):
    txt = txt.strip()
    return txt.startswith("{") and txt.endswith("}")


def _pl_normalize_final(obj):
    # Normalize to: {"status":"final","result":{"streamed":<bool>,"out_path":"<str>"}}
    streamed = bool(obj.get("streamed") or (obj.get("result") or {}).get("streamed"))
    out_path = (obj.get("result") or {}).get("out_path") or obj.get("out_path")
    if isinstance(
        out_path, dict
    ):  # collapse accidental nested {"out_path": {"out_path": "..."}}
        out_path = (
            out_path.get("out_path") or out_path.get("path") or out_path.get("file")
        )
    res = {"streamed": streamed}
    if out_path:
        res["out_path"] = str(out_path)
    return {"status": "final", "result": res}


def _pl_guard_print(*args, **kwargs):
    global _PL_FINAL_SENT
    if len(args) == 1 and isinstance(args[0], str) and _pl_is_json_obj(args[0]):
        try:
            obj = _pl_json.loads(args[0])
        except Exception:
            return _PL_ORIG_PRINT(*args, **kwargs)

        # Suppress any bare {"out_path": "..."} or similar after final
        if (
            _PL_FINAL_SENT
            and isinstance(obj, dict)
            and "status" not in obj
            and ("out_path" in obj or "streamed" in obj)
        ):
            return

        # Normalize and dedupe "final"
        if isinstance(obj, dict) and obj.get("status") == "final":
            if _PL_FINAL_SENT:
                return
            _PL_FINAL_SENT = True
            norm = _pl_normalize_final(obj)
            _PL_ORIG_PRINT(_pl_json.dumps(norm, ensure_ascii=False), **kwargs)
            _pl_sys.stdout.flush()
            return

    return _PL_ORIG_PRINT(*args, **kwargs)


_pl_builtins.print = _pl_guard_print

# Provide a safe fallback if synopsis rewriter is missing
try:
    _pl_rewrite_synopsis  # type: ignore[name-defined]
except Exception:

    def _pl_rewrite_synopsis(text, *a, **k):  # noqa: N802
        return text


# ==== /PL PATCH ====
# polarity_sentiment.py
# ---------------------------------------------------------------
# Local-only sentiment pipeline for PolarityLab
#   • NLTK VADER (with optional emoji & spaCy negation support)
#   • twitter-RoBERTa ("social") from local folder
#   • distilbert-sst2 ("community") from local folder (2-label safe)
#   • ORIGINAL JSON contract (rows, row_headers, keywords_comp)
#   • JSONL streaming to PL_OUT to avoid huge stdout
#   • Template overrides + keyword filtering + explanations
#   • Date filtering (auto-detect created_at / ISO-8601), timeline, synopsis
#   • Signature/@handle stripping with user overrides (Settings → env)
#   • Auto-tuned batching, max length, chunks, and threads with env overrides
#   • Libraries silenced (HF/tokenizers/spaCy/warnings)
#   • Daily timeline by default; UI can aggregate to week/month
#   • Always include drivers and full-detail synopsis when requested
#   • Optional PDF export with Title/H1/H2 formatting
#   • Robust Post ID detection: --postid > PL_POST_ID_COL > name hints > duplication heuristic
#   • Top posts (by duplicate Post ID) and overall drivers included in synopsis/PDF
# ---------------------------------------------------------------

from typing import Any

from typing import Any, Iterable


def _canon_key(x: Any):
    if isinstance(x, list):
        return tuple(_canon_key(v) for v in x)
    if isinstance(x, set):
        return tuple(sorted(_canon_key(v) for v in x))
    if isinstance(x, dict):
        return tuple(sorted((str(k), _canon_key(v)) for k, v in x.items()))
    if isinstance(x, tuple):
        return tuple(_canon_key(v) for v in x)
    return x


class HashKeyDict(dict):
    def __key(self, k):
        return _canon_key(k)

    def __getitem__(self, k):
        return super().__getitem__(self.__key(k))

    def __setitem__(self, k, v):
        return super().__setitem__(self.__key(k), v)

    def __contains__(self, k):
        return super().__contains__(self.__key(k))

    def get(self, k, d=None):
        return super().get(self.__key(k), d)

    def setdefault(self, k, d=None):
        return super().setdefault(self.__key(k), d)

    def pop(self, k, *a):
        return super().pop(self.__key(k), *a)

    def update(self, other=None, **kw):
        if other:
            if isinstance(other, dict):
                for k, v in other.items():
                    super().__setitem__(self.__key(k), v)
            else:
                for k, v in other:
                    super().__setitem__(self.__key(k), v)
        for k, v in kw.items():
            super().__setitem__(self.__key(k), v)


def _mk_key(k: Any):
    return tuple(k) if isinstance(k, (list, tuple, set)) else k


import os, sys, re, json, argparse, math, warnings, logging
from pathlib import Path
from typing import List, Tuple, Dict, Any, Iterable, Optional
import traceback
import tempfile

# Detect if invoked in serve mode (so we can delay heavy imports)
_IN_SERVE_MODE = len(sys.argv) >= 2 and sys.argv[1] == "serve"


def _dbg(msg):
    if os.environ.get("PL_DEBUG", "0") != "0":
        print(f"[PL] {msg}", file=sys.stderr, flush=True)


# terse timestamped stderr logger
import time as _t__  # local alias to avoid shadowing


def T(msg: str):
    try:
        sys.stderr.write(f"[T] {_t__.strftime('%H:%M:%S')} {msg}\n")
        sys.stderr.flush()
    except Exception:
        pass


# --- Early helper fallback to avoid NameError during serve loop ---
try:
    _pl_rewrite_synopsis
except NameError:

    def _pl_rewrite_synopsis(original: str, meta: dict) -> str:
        return original or ""


# ───────────────────────────────────────────────────────────────
# Belt-and-suspenders offline/cache defaults
# ───────────────────────────────────────────────────────────────
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_DATASETS_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
os.environ.setdefault("TRANSFORMERS_NO_ADVISORY_WARNINGS", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
# Safe cache fallback if host app did not set one
try:
    _cache_base = Path(
        os.environ.get("PL_CACHE_DIR", str(Path(tempfile.gettempdir()) / "pl_cache"))
    ).resolve()
    os.environ.setdefault("HF_HOME", str(_cache_base / "hf"))
    os.environ.setdefault(
        "TRANSFORMERS_CACHE", str(_cache_base / "hf" / "transformers")
    )
    os.environ.setdefault("HF_DATASETS_CACHE", str(_cache_base / "hf" / "datasets"))
except Exception:
    pass

warnings.filterwarnings("ignore")
# Make transformers logging lazy. Do NOT import transformers here.

logging.getLogger("spacy").setLevel(logging.ERROR)

# Settings-driven toggles (from Swift Settings pane → env)
PL_SIGNATURES_ENABLED = os.environ.get("PL_SIGNATURES_ENABLED", "1") != "0"
PL_USERNAME_REMOVAL = os.environ.get("PL_USERNAME_REMOVAL", "1") != "0"
PL_SIG_EXTRA = os.environ.get(
    "PL_SIG_EXTRA", ""
)  # newline/comma-separated extra signature cues
PL_OUT = os.environ.get("PL_OUT", "")  # if set, stream JSONL here

# Output shape toggles
EMIT_DRIVERS = os.environ.get("PL_EMIT_DRIVERS_COL", "0") != "0"
EMIT_SIGNATURE = os.environ.get("PL_EMIT_SIGNATURE_COL", "1") != "0"

# Optional PDF path from env (CLI flag preferred)
PL_PDF_OUT = os.environ.get("PL_PDF_OUT", "")

# Preferred timeline grouping (D/W/M). Default = daily for rich charts.
PL_TIMELINE_GROUP = os.environ.get("PL_TIMELINE_GROUP", "D").upper()
if PL_TIMELINE_GROUP not in {"D", "W", "M"}:
    PL_TIMELINE_GROUP = "D"

# Progress heartbeats
PL_PROGRESS_EVERY = int(os.environ.get("PL_PROGRESS_EVERY", "100"))


# ───────────────────────────────────────────────────────────────
# Auto-tuning (CPU-only; Apple/Intel alike) with env overrides
# ───────────────────────────────────────────────────────────────
def _clamp(v: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, v))


def _detect_ram_gb() -> int:
    # try psutil
    try:
        import psutil

        return int(psutil.virtual_memory().total / 1e9)
    except Exception:
        pass
    # unix sysconf
    try:
        pages = os.sysconf("SC_PHYS_PAGES")
        psize = os.sysconf("SC_PAGE_SIZE")
        return int((pages * psize) / 1e9)
    except Exception:
        pass
    # fallback
    return 8


def _autotune_defaults() -> Dict[str, int]:
    RAM_GB = _detect_ram_gb()
    CORES = os.cpu_count() or 4
    profile = os.getenv("PL_PERF_PROFILE", "auto").lower()
    if profile not in {"auto", "throughput", "battery"}:
        profile = "auto"

    # Batch for RoBERTa “social” (used as base also for other transformers)
    base = 32
    scale = int((RAM_GB / 8.0) * (CORES**0.5))
    scale = _clamp(scale, 1, 4)
    if profile == "throughput":
        scale = max(1, int(scale * 1.5))
    elif profile == "battery":
        scale = max(1, int(scale * 0.75))
    batch = _clamp(int(base * scale), 16, 512)

    # Max seq length
    maxlen = 128 if profile != "battery" else 96

    # CSV read chunksize
    chunksize = _clamp(RAM_GB * 4000, 8000, 50000)

    # Threads (unless user set)
    if os.getenv("OMP_NUM_THREADS") is None or os.getenv("MKL_NUM_THREADS") is None:
        if CORES <= 4:
            omp = 1
        else:
            omp = min(4, CORES // 2)
        os.environ.setdefault("OMP_NUM_THREADS", str(omp))
        os.environ.setdefault("MKL_NUM_THREADS", str(omp))

    if os.environ.get("PL_DEBUG", "0") != "0":
        _dbg(
            f"AUTOTUNE RAM_GB={RAM_GB} CORES={CORES} profile={profile} "
            f"-> BATCH={batch} MAXLEN={maxlen} CHUNKSIZE={chunksize} "
            f"OMP={os.getenv('OMP_NUM_THREADS')} MKL={os.getenv('MKL_NUM_THREADS')}"
        )

    return {"BATCH": batch, "MAXLEN": maxlen, "CHUNKSIZE": chunksize}


def _as_int(env_key: str, default: int) -> int:
    try:
        return int(os.environ.get(env_key, str(default)))
    except Exception:
        return default


# Resolve auto-tuned defaults, then let env override
_auto = _autotune_defaults()
BATCH = _as_int("PL_BATCH", _auto["BATCH"])
MAXLEN = _as_int("PL_MAXLEN", _auto["MAXLEN"])
CHUNKSIZE = _as_int("PL_CHUNKSIZE", _auto["CHUNKSIZE"])

if os.environ.get("PL_DEBUG", "0") != "0":
    msg = f"FINAL PARAMS BATCH={BATCH} MAXLEN={MAXLEN} CHUNKSIZE={CHUNKSIZE}"
    _dbg(msg)
    T(msg)

# ───────────────────────────────────────────────────────────────
# Local resource paths
# ───────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent
SOCIAL_MODEL_DIR = BASE_DIR / "twitter-roberta-base-sentiment"
COMMUNITY_MODEL_DIR = BASE_DIR / "distilbert-sst2"
SPACY_MODEL_DIR = BASE_DIR / "en_core_web_sm"
EMOJI_LEXICON = BASE_DIR / "emoji_utf8_lexicon.txt"  # optional
VADER_LEXICON = BASE_DIR / "vader_lexicon.txt"  # optional

# ───────────────────────────────────────────────────────────────
# Lazy heavy imports (pandas/numpy) to let serve handshake print fast
# ───────────────────────────────────────────────────────────────
pd = None  # type: ignore
np = None  # type: ignore


def _ensure_pd_np():
    """Load pandas and numpy only when needed."""
    global pd, np
    if pd is None:
        import pandas as _pd  # noqa

        pd = _pd
    if np is None:
        import numpy as _np  # noqa

        np = _np


# ───────────────────────────────────────────────────────────────
# JSON safety
# ───────────────────────────────────────────────────────────────
def _json_safe(v):
    # Handle None and plain types fast
    if v is None or isinstance(v, (bool, int, float, str)):
        # normalize weird floats
        if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
            return None
        return v
    # Numpy numbers
    try:
        if np is not None and isinstance(v, (np.floating,)):
            f = float(v)
            return None if (math.isnan(f) or math.isinf(f)) else f
        if np is not None and isinstance(v, (np.integer,)):
            return int(v)
    except Exception:
        pass
    # Pandas NA
    try:
        if pd is not None and hasattr(pd, "isna") and pd.isna(v):
            return None
    except Exception:
        pass
    # Pandas timestamp/period
    try:
        if pd is not None and isinstance(v, pd.Timestamp):
            try:
                return v.tz_convert("UTC").isoformat()
            except Exception:
                return v.isoformat()
        if pd is not None and isinstance(v, pd.Period):
            return str(v)
    except Exception:
        pass
    return str(v)


def _dumps(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, allow_nan=False)


# ───────────────────────────────────────────────────────────────
# Signature / handle stripping (with user overrides)
# ───────────────────────────────────────────────────────────────
_SIG_CUES = [
    r"thanks",
    r"thank you",
    r"best(?: regards)?",
    r"regards",
    r"cheers",
    r"sincerely",
    r"kind regards",
    r"many thanks",
    r"sent from my (?:iphone|ipad|android|phone)",
]
_SIG_CUES_LOCALE = [
    r"cordialement",
    r"saludos",
    r"mit freundlichen grüßen",
    r"gruß",
    r"grazie",
    r"merci",
]


def _compile_sig_regex():
    extra = []
    if PL_SIG_EXTRA.strip():
        raw = re.split(r"[\n,]+", PL_SIG_EXTRA)
        extra = [re.escape(s.strip()) for s in raw if s.strip()]
    cues = _SIG_CUES + _SIG_CUES_LOCALE + extra
    if not cues:
        return re.compile(r"$(?!. )")  # never matches
    pat = r"^(?:" + r"|".join(cues) + r")\b[:,\-–—]*"
    return re.compile(pat, re.IGNORECASE)


SIG_RX = _compile_sig_regex()
CONTACT_RX = re.compile(
    r"(\+?\d[\d\-\s().]{6,}\d|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|https?://|www\.)",
    re.IGNORECASE,
)
DELIM_RX = re.compile(r"^[-_•=]{3,}\s*$")
MENTION_RX = re.compile(r"(?<!\w)@\w{1,30}\b")


def _strip_signature_and_handles(text: str) -> Tuple[str, str, int]:
    """
    Returns (clean_text, removed_signature_block, removed_handles_count)
    Applies user overrides via PL_SIG_EXTRA and PL_USERNAME_REMOVAL.
    """
    if not text:
        return text, "", 0
    if len(text) < 8:
        if PL_USERNAME_REMOVAL:
            return MENTION_RX.sub(" ", text), "", len(re.findall(MENTION_RX, text))
        return text, "", 0

    # Remove quoted/original markers
    lines: List[str] = []
    for raw in str(text).splitlines():
        l = raw.rstrip()
        if l.startswith(">") or l.startswith("|"):
            continue
        if re.search(r"^-----.*original message.*-----$", l, re.IGNORECASE):
            break
        if re.search(r"^(From|Sent|To|Subject):", l, re.IGNORECASE):
            continue
        lines.append(l)

    before = "\n".join(lines)
    after = MENTION_RX.sub(" ", before) if PL_USERNAME_REMOVAL else before
    removed_handles = len(re.findall(MENTION_RX, before)) if PL_USERNAME_REMOVAL else 0

    if not PL_SIGNATURES_ENABLED:
        return after.strip(), "", removed_handles

    # Bottom-up footer scoring
    lines2 = [l.rstrip() for l in after.splitlines()]
    score, cut_at = 0.0, len(lines2)
    for i in range(len(lines2) - 1, -1, -1):
        ln = lines2[i].strip()
        s = 0.0 if ln else 0.25
        if SIG_RX.search(ln):
            s += 3.0
        if CONTACT_RX.search(ln):
            s += 2.0
        if DELIM_RX.search(ln):
            s += 2.0
        toks = ln.split()
        if toks and 1 <= len(toks) <= 6 and toks[0][0:1].isupper():
            titlecase_ratio = sum(t.istitle() for t in toks) / len(toks)
            if titlecase_ratio > 0.5:
                s += 1.0
        if (
            len(ln) <= 64
            and ln.count(".") <= 1
            and not re.search(r"\b(am|is|are|was|were|be|have|do)\b", ln, re.I)
        ):
            s += 0.5
        score += s
        if score >= 5.0:
            cut_at = i
            break
        if len(ln) > 140 or re.search(r"[.!?].*\b\w+\b.*[.!?]", ln):
            score = max(0.0, score - 2.0)

    clean = "\n".join(lines2[:cut_at]).strip()
    footer = "\n".join(lines2[cut_at:]).strip() if cut_at < len(lines2) else ""
    return (clean if clean else after.strip()), footer, removed_handles


# ───────────────────────────────────────────────────────────────
# Global caches / lazy loads
# ───────────────────────────────────────────────────────────────
_model_cache: Dict[str, Any] = {}


def _load_vader():
    if "vader" in _model_cache:
        return _model_cache["vader"]
    from nltk.sentiment.vader import SentimentIntensityAnalyzer

    analyzer = (
        SentimentIntensityAnalyzer(lexicon_file=str(VADER_LEXICON))
        if VADER_LEXICON.exists()
        else SentimentIntensityAnalyzer()
    )
    base = analyzer.lexicon.copy()
    if EMOJI_LEXICON.exists():
        try:
            text = EMOJI_LEXICON.read_text(encoding="utf-8")
            for raw in text.splitlines():
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t", 1)
                if len(parts) != 2:
                    continue
                emoji, desc = parts
                words = re.findall(r"\b\w+\b", desc.lower())
                s = sum(base.get(w, 0.0) for w in words)
                if s:
                    analyzer.lexicon[f" {emoji} "] = s
        except Exception:
            pass
    _model_cache["vader"] = analyzer
    return analyzer


def _load_spacy():
    if "spacy_loaded" in _model_cache:
        return _model_cache.get("nlp")
    try:
        import spacy

        if str(SPACY_MODEL_DIR) not in sys.path:
            sys.path.insert(0, str(SPACY_MODEL_DIR))
        nlp = spacy.load(str(SPACY_MODEL_DIR))
        _model_cache["nlp"] = nlp
        _model_cache["spacy_available"] = True
    except Exception:
        _model_cache["nlp"] = None
        _model_cache["spacy_available"] = False
    _model_cache["spacy_loaded"] = True
    return _model_cache.get("nlp")


def _spacy_negation_detected(text: str) -> bool:
    if not _model_cache.get("spacy_available", False):
        return False
    try:
        nlp = _model_cache.get("nlp") or _load_spacy()
        if not nlp:
            return False
        doc = nlp(text)
        return any(
            tok.dep_ == "neg" and tok.head.pos_ in {"ADJ", "VERB"} for tok in doc
        )
    except Exception:
        return False


def _load_transformers():
    if "tf" in _model_cache:
        return
    # Import transformers only when actually needed, and silence logging then
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    try:
        from transformers.utils import logging as hf_log

        hf_log.set_verbosity_error()
    except Exception:
        pass
    _model_cache["tf"] = True
    # social (3 labels)
    try:
        sm = AutoModelForSequenceClassification.from_pretrained(
            str(SOCIAL_MODEL_DIR), local_files_only=True
        )
        st = AutoTokenizer.from_pretrained(str(SOCIAL_MODEL_DIR), local_files_only=True)
        _model_cache["social"] = (sm, st)
    except Exception:
        _model_cache["social"] = None
    # community (2 or 3 labels)
    try:
        cm = AutoModelForSequenceClassification.from_pretrained(
            str(COMMUNITY_MODEL_DIR), local_files_only=True
        )
        ct = AutoTokenizer.from_pretrained(
            str(COMMUNITY_MODEL_DIR), local_files_only=True
        )
        _model_cache["community"] = (cm, ct)
    except Exception:
        _model_cache["community"] = None


# ───────────────────────────────────────────────────────────────
# Utility
# ───────────────────────────────────────────────────────────────
def _token_list(text: str) -> List[str]:
    return re.findall(r"\b\w+\b", text.lower())


def _apply_model_batch(texts: List[str], model_choice: str) -> List[Dict[str, Any]]:
    """
    Batched scoring for transformer models; VADER fallback per-item.
    Returns list of dicts with pos/neu/neg/compound/model_label/conf/used.
    """
    res: List[Dict[str, Any]] = []
    if model_choice in ("social", "community"):
        _load_transformers()
        pack = _model_cache.get(model_choice)
        if pack:
            from transformers import TextClassificationPipeline

            model, tok = pack
            pipe = TextClassificationPipeline(
                model=model, tokenizer=tok, return_all_scores=True, truncation=True
            )
            for i in range(0, len(texts), BATCH):
                chunk = texts[i : i + BATCH]
                out = pipe(
                    chunk,
                    top_k=None,
                    truncation=True,
                    max_length=MAXLEN,
                    batch_size=min(BATCH, 16),
                )
                for scores in out:
                    lbl_to_score = {
                        d["label"].upper(): float(d["score"]) for d in scores
                    }
                    mapped: Dict[str, float] = {}
                    for k, v in lbl_to_score.items():
                        if k.startswith("LABEL_"):
                            idx = k.split("_")[-1]
                            k = (
                                {"0": "NEGATIVE", "1": "POSITIVE"}.get(idx, "NEUTRAL")
                                if len(lbl_to_score) == 2
                                else {
                                    "0": "NEGATIVE",
                                    "1": "NEUTRAL",
                                    "2": "POSITIVE",
                                }.get(idx, "NEUTRAL")
                            )
                        mapped[k] = v
                    neg = mapped.get("NEGATIVE", 0.0)
                    neu = mapped.get("NEUTRAL", 0.0)
                    pos = mapped.get("POSITIVE", 0.0)
                    compound = pos - neg
                    mlabel = max(mapped, key=mapped.get) if mapped else "NEUTRAL"
                    mconf = round(mapped.get(mlabel, 0.0), 3)
                    res.append(
                        dict(
                            pos=pos,
                            neu=neu,
                            neg=neg,
                            compound=compound,
                            model_label=mlabel,
                            model_confidence=mconf,
                            used=model_choice,
                        )
                    )
            return res

    # Fallback: VADER
    analyzer = _load_vader()
    for t in texts:
        vs = analyzer.polarity_scores(t)
        comp = vs["compound"]
        if comp >= 0.05:
            mlabel = "POSITIVE"
        elif comp <= -0.05:
            mlabel = "NEGATIVE"
        else:
            mlabel = "NEUTRAL"
        res.append(
            dict(
                pos=vs["pos"],
                neu=vs["neu"],
                neg=vs["neg"],
                compound=comp,
                model_label=mlabel,
                model_confidence=1.0,
                used="vader",
            )
        )
    return res


def _compile_template(tpl_json) -> Dict[str, List[Tuple[re.Pattern, float]]]:
    if not tpl_json:
        return {"vader_phrases": [], "bias_phrases": []}
    tpl = tpl_json if isinstance(tpl_json, dict) else json.loads(tpl_json)

    def mk_regex(p):
        return re.compile(rf"(?<!\w){re.escape(p)}(?!\w)", re.IGNORECASE)

    vlist = [
        (mk_regex(it["phrase"]), float(it["score"]))
        for it in tpl.get("vader", [])
        if it.get("phrase")
    ]
    blist = [
        (mk_regex(it["phrase"]), float(it["score"]))
        for it in tpl.get("bias", [])
        if it.get("phrase")
    ]
    return {"vader_phrases": vlist, "bias_phrases": blist}


def _template_kw_override_map(template) -> dict:
    """
    Build phrase→effective_score in [-1,1] from the provided template.
    Uses same scaling as _apply_overrides: bias → val, vader → val/4.
    """
    import json as _json

    if not template:
        return {}
    try:
        t = template if isinstance(template, dict) else _json.loads(str(template))
    except Exception:
        return {}
    out = {}
    for it in t.get("bias") or []:
        try:
            phr = (it.get("phrase") or "").strip()
            if not phr:
                continue
            val = float(it.get("score", 0.0))
            out[phr.lower()] = max(-1.0, min(1.0, val))
        except Exception:
            continue
    for it in t.get("vader") or []:
        try:
            phr = (it.get("phrase") or "").strip()
            if not phr:
                continue
            val = float(it.get("score", 0.0)) / 4.0
            out[phr.lower()] = max(-1.0, min(1.0, val))
        except Exception:
            continue
    return out


def _apply_template_overrides_to_kwlist(kw_list, template):
    """
    Return a new keywords_comp list with template phrase scores applied/added.
    """
    ov = _template_kw_override_map(template)
    if not ov:
        return kw_list
    out = [dict(d) for d in (kw_list or [])]
    idx = {}
    for i, d in enumerate(out):
        name = (d.get("word") or d.get("token") or d.get("term") or "").strip().lower()
        if name:
            idx.setdefault(name, i)
    for phr, eff in ov.items():
        if phr in idx:
            out[idx[phr]]["compound"] = round(float(eff), 2)
        else:
            out.append({"word": phr, "compound": round(float(eff), 2)})
    try:
        out.sort(key=lambda d: -abs(float(d.get("compound", 0.0))))
    except Exception:
        pass
    return out


def _apply_overrides(
    text: str, base_compound: float, template_obj
) -> Tuple[float, List[Dict[str, Any]]]:
    comp = base_compound
    drivers: List[Dict[str, Any]] = []
    for rx, val in template_obj["vader_phrases"]:
        cnt = len(rx.findall(text))
        if cnt:
            delta = cnt * (float(val) / 4.0)
            comp += delta
            drivers.append(
                {
                    "phrase": rx.pattern,
                    "kind": "vader",
                    "count": cnt,
                    "delta": round(delta, 3),
                }
            )
    for rx, val in template_obj["bias_phrases"]:
        cnt = len(rx.findall(text))
        if cnt:
            delta = cnt * float(val)
            comp += delta
            drivers.append(
                {
                    "phrase": rx.pattern,
                    "kind": "bias",
                    "count": cnt,
                    "delta": round(delta, 3),
                }
            )
    return max(-1.0, min(1.0, comp)), drivers


def _passes_filter(text: str, filt_json) -> bool:
    """
    Return True if `text` matches the provided filter.

    Supports BOTH legacy keyword mode:
      {"keywords":[...], "mode":"any|all", "caseSensitive":bool, "wholeWord":bool}

    And regex pattern mode (preferred):
      {"patterns":[...], "mode":"any|all", "caseSensitive":bool}
      {"regexes":[...], ...}  # alias

    Robustness:
      * Escapes keywords safely before compiling.
      * Compiles each pattern independently and skips any that fail.
      * Whole-word uses lookarounds that are fixed-length and safe.
      * Final fallback to substring checks so no PatternError can crash.
    """
    import re, json as _json

    # Nothing to filter by -> allow everything
    if not filt_json:
        return True

    # Parse filter object if JSON string
    try:
        f = filt_json if isinstance(filt_json, dict) else _json.loads(str(filt_json))
    except Exception:
        return True

    mode = str(f.get("mode", "any")).lower()
    cs = bool(f.get("caseSensitive", False))
    ww = bool(f.get("wholeWord", False))
    flags = 0 if cs else re.IGNORECASE

    txt = "" if text is None else str(text)

    patterns = []

    # Preferred explicit regex patterns
    for key in ("patterns", "regexes", "rx"):
        seq = f.get(key)
        if not seq:
            continue
        if isinstance(seq, str):
            seq = [seq]
        for p in seq:
            try:
                patterns.append(re.compile(str(p), flags))
            except re.error:
                # If the provided regex is invalid, escape it and try again
                try:
                    patterns.append(re.compile(re.escape(str(p)), flags))
                except re.error:
                    # Skip utterly broken entries
                    continue

    # Legacy keywords → compile safely, with optional whole-word
    kws = f.get("keywords") or f.get("words") or []
    if isinstance(kws, str):
        kws = [kws]
    for k in kws:
        k = str(k)
        if not k:
            continue
        base = re.escape(k.strip())
        if not base:
            continue
        pat = rf"(?<!\w){base}(?!\w)" if ww else base
        try:
            patterns.append(re.compile(pat, flags))
        except re.error:
            # As a last resort, try a super-escaped literal
            try:
                patterns.append(re.compile(re.escape(k), flags))
            except re.error:
                continue

    # If we couldn't build any regexes, allow all (no-op filter)
    if not patterns:
        return True

    # Safe matcher using compiled patterns
    def _hit(rx, s):
        try:
            return rx.search(s) is not None
        except Exception:
            return False

    try:
        return (
            all(_hit(r, txt) for r in patterns)
            if mode == "all"
            else any(_hit(r, txt) for r in patterns)
        )
    except Exception:
        # Ultra-safe fallback: plain substring checks
        norm = txt if cs else txt.lower()
        terms = []
        for rx in patterns:
            # Extract something usable from the regex to fallback on
            s = getattr(rx, "pattern", "")
            if not s:
                continue
            # Best-effort: remove lookarounds added for whole-word
            s = s.replace("(?<!\\w)", "").replace("(?!\\w)", "")
            # De-escape common escapes
            s = s.replace("\\.", ".").replace("\\-", "-").replace("\\_", "_")
            terms.append(s if cs else s.lower())
        if not terms:
            return True
        return (
            all(t in norm for t in terms)
            if mode == "all"
            else any(t in norm for t in terms)
        )


# ───────────────────────────────────────────────────────────────
# Auto date detection
# ───────────────────────────────────────────────────────────────
DATE_CANDIDATE_COLS = [
    "created_at",
    "createdAt",
    "created",
    "timestamp",
    "ts",
    "time",
    "date",
    "datetime",
    "posted_at",
    "postedAt",
    "updated_at",
    "published_at",
    "pub_date",
]


def _detect_date_column(df) -> Optional[str]:
    # prefer explicit candidates
    for c in df.columns:
        lc = str(c).strip()
        if lc in DATE_CANDIDATE_COLS:
            return c
    # heuristic: look for ISO-like strings in samples
    try:
        s = df.astype(str).head(50)
    except Exception:
        return None
    for c in list(df.columns):
        try:
            col = s[c]
        except Exception:
            continue
        hit = (col.str.contains(r"^\d{4}-\d{2}-\d{2}", regex=True)).mean() > 0.6
        if hit:
            return c
    return None


# ───────────────────────────────────────────────────────────────
# Core APIs
# ───────────────────────────────────────────────────────────────
def score_sentence(
    text: str, model_choice: str, template=None, explain: bool = False
) -> str:
    # No _ensure_pd_np() here by design. Keep serve-score lightweight.
    if model_choice == "vader":
        _load_spacy()
    clean_text, removed_sig, removed_handles = _strip_signature_and_handles(text)
    model_out = _apply_model_batch([clean_text], model_choice)[0]
    comp_adj, drivers = _apply_overrides(
        clean_text, model_out["compound"], _compile_template(template)
    )
    include_spacy_flag = model_out["used"] == "vader"
    is_neg = _spacy_negation_detected(clean_text) if include_spacy_flag else False
    if comp_adj >= 0.05:
        base_lbl = "POSITIVE"
    elif comp_adj <= -0.05:
        base_lbl = "NEGATIVE"
    else:
        base_lbl = "NEUTRAL"
    final_label = (
        ("NEGATIVE" if base_lbl == "POSITIVE" else "POSITIVE")
        if (include_spacy_flag and is_neg)
        else base_lbl
    )
    row = {
        "text": clean_text,
        "pos": model_out["pos"],
        "neu": model_out["neu"],
        "neg": model_out["neg"],
        "compound": comp_adj,
        "model_label": model_out["model_label"],
        "model_confidence": model_out["model_confidence"],
        "final_sentiment": final_label,
        "used": model_out["used"],
    }
    if include_spacy_flag:
        row["spacy_negation"] = is_neg
    if explain:
        row["drivers"] = drivers
        if EMIT_SIGNATURE:
            row["removed_signature"] = removed_sig or ""
            row["removed_handles"] = int(removed_handles or 0)
    headers = [
        "text",
        "pos",
        "neu",
        "neg",
        "compound",
        "model_label",
        "model_confidence",
        "final_sentiment",
        "used",
    ]
    if include_spacy_flag:
        headers.append("spacy_negation")
    if explain and "drivers" not in headers:
        headers.append("drivers")
    if explain and EMIT_SIGNATURE:
        if "removed_signature" not in headers:
            headers.append("removed_signature")
        if "removed_handles" not in headers:
            headers.append("removed_handles")
    return _dumps({"rows": [row], "row_headers": headers, "keywords_comp": []})


def _results_iter(
    df,
    selected_columns: List[str],
    merge_text: bool,
    model_choice: str,
    template,
    filt,
    explain: bool,
) -> Iterable[Tuple[Dict[str, Any], str]]:
    tpl = _compile_template(template)
    include_spacy_flag = model_choice == "vader"

    batch_rows: List[Tuple[Any, str, str, str, int]] = []
    batch_texts: List[str] = []

    def process_batch():
        if not batch_texts:
            return
        scored = _apply_model_batch(batch_texts, model_choice)
        for model_out, (
            row,
            orig_text,
            clean_text,
            removed_sig,
            removed_handles,
        ) in zip(scored, batch_rows):
            comp_adj, drivers = _apply_overrides(clean_text, model_out["compound"], tpl)
            if comp_adj >= 0.05:
                base_lbl = "POSITIVE"
            elif comp_adj <= -0.05:
                base_lbl = "NEGATIVE"
            else:
                base_lbl = "NEUTRAL"
            is_neg = (
                _spacy_negation_detected(clean_text)
                if (model_out["used"] == "vader")
                else False
            )
            final_label = (
                ("NEGATIVE" if base_lbl == "POSITIVE" else "POSITIVE")
                if is_neg
                else base_lbl
            )

            rec = {c: _json_safe(row[c]) for c in list(df.columns)}
            rec.update(
                {
                    "__dt": rec.get("__dt"),
                    "__bucket": rec.get("__bucket"),
                    "pos": model_out["pos"],
                    "neu": model_out["neu"],
                    "neg": model_out["neg"],
                    "compound": comp_adj,
                    "compound_raw": model_out["compound"],
                    "compound_override": round(comp_adj - model_out["compound"], 4),
                    "compound_effective": comp_adj,
                    "model_label": model_out["model_label"],
                    "model_confidence": model_out["model_confidence"],
                    "final_sentiment": final_label,
                    "used": model_out["used"],
                }
            )
            if include_spacy_flag:
                rec["spacy_negation"] = is_neg
            if "text" not in rec and len(selected_columns) == 1:
                rec["text"] = clean_text
            if explain:
                rec["drivers"] = drivers
                if EMIT_SIGNATURE:
                    rec["removed_signature"] = removed_sig or ""
                    rec["removed_handles"] = int(removed_handles or 0)
            yield rec, clean_text

    # single guarded row loop
    for i, (_, row) in enumerate(df.iterrows()):
        try:
            if merge_text and len(selected_columns) > 1:
                text = " ".join(str(row.get(c, "")) for c in selected_columns)
            else:
                col = selected_columns[0] if selected_columns else list(df.columns)[0]
                text = str(row.get(col, ""))

            if not _passes_filter(text, filt):
                continue

            clean_text, removed_sig, removed_handles = _strip_signature_and_handles(
                text
            )
            batch_rows.append((row, text, clean_text, removed_sig, removed_handles))
            batch_texts.append(clean_text)

            if len(batch_texts) >= BATCH:
                for item in process_batch():
                    yield item
                batch_rows.clear()
                batch_texts.clear()
        except Exception as e:
            _dbg(f"row_fail i={i}: {e}")
            print(
                json.dumps(
                    {
                        "__error__": True,
                        "where": "results_iter",
                        "row_index": i,
                        "msg": str(e),
                    }
                ),
                file=sys.stderr,
                flush=True,
            )
            continue

    # final partial batch
    for item in process_batch():
        yield item


def _accumulate_meta(
    meta_ctx,
    clean_text: str,
    comp_adj: float,
    drivers: List[Dict[str, Any]],
    bucket_key: Optional[str],
):
    """Accumulate per-token comps, timeline stats, and driver summaries."""
    analyzer = _load_vader()

    # keyword comps
    for tok in _token_list(clean_text):
        comp_tok = analyzer.polarity_scores(tok)["compound"]
        s, c = meta_ctx["kw_comps"].get(tok, (0.0, 0))
        meta_ctx["kw_comps"][tok] = (s + comp_tok, c + 1)

    # drivers summary
    for d in drivers:
        k = (d["phrase"], d["kind"])
        cur = meta_ctx["drivers"].get(k, {"count": 0, "delta": 0.0})
        meta_ctx["drivers"][k] = {
            "count": cur["count"] + d["count"],
            "delta": round(cur["delta"] + d["delta"], 3),
        }

    # timeline
    if bucket_key:
        meta_ctx["tl_counts"][bucket_key] = meta_ctx["tl_counts"].get(bucket_key, 0) + 1
        meta_ctx["tl_sum"][bucket_key] = meta_ctx["tl_sum"].get(
            bucket_key, 0.0
        ) + float(comp_adj)
        if "tl_drivers" in meta_ctx:
            bd = meta_ctx["tl_drivers"].setdefault(bucket_key, {})
            for d in drivers:
                k = (d["phrase"], d["kind"])
                cur = bd.get(k, {"count": 0, "delta": 0.0})
                bd[k] = {
                    "count": cur["count"] + d["count"],
                    "delta": round(cur["delta"] + d["delta"], 3),
                }


def _finalize_keywords(kw_comps: Dict[str, Any]) -> List[Dict[str, Any]]:
    def avg(v):
        if isinstance(v, tuple) and len(v) == 2:
            s, c = v
            return s / (c or 1)
        if isinstance(v, list):
            return sum(v) / (len(v) or 1)
        return float(v)

    items = [(w, avg(v)) for w, v in kw_comps.items()]
    items.sort(key=lambda kv: -abs(kv[1]))
    return [{"word": w, "compound": round(val, 2)} for w, val in items]


def _timeline_from_meta(meta_ctx, grp: Optional[str]):
    _ensure_pd_np()
    tl = []
    if not meta_ctx["tl_counts"]:
        return tl

    def sort_key(k):
        try:
            if grp == "M":
                return pd.Period(k, freq="M")
            if grp == "W":
                return pd.Period(k, freq="W-MON")
            if grp == "D":
                return pd.Period(k, freq="D")
        except Exception:
            pass
        return str(k)

    def bucket_start_iso(k):
        try:
            if grp == "M":
                p = pd.Period(k, freq="M")
                return p.start_time.normalize().strftime("%Y-%m-%d")
            if grp == "W":
                p = pd.Period(k, freq="W-MON")
                return p.start_time.normalize().strftime("%Y-%m-%d")
            if isinstance(k, pd.Period):
                return k.start_time.normalize().strftime("%Y-%m-%d")
            s = str(k)
            if re.match(r"^\d{4}-\d{2}$", s):
                return pd.Period(s, freq="M").start_time.strftime("%Y-%m-%d")
            if re.match(r"^\d{4}-\d{2}-\d{2}", s):
                return s[:10]
        except Exception:
            pass
        return str(k)

    for b in sorted(meta_ctx["tl_counts"].keys(), key=sort_key):
        label = bucket_start_iso(b)
        top = []
        if meta_ctx.get("tl_drivers"):
            bd = meta_ctx["tl_drivers"].get(b, {})
            top = sorted(
                [
                    {"phrase": p, "kind": k, "count": v["count"], "delta": v["delta"]}
                    for (p, k), v in bd.items()
                ],
                key=lambda x: -abs(x["delta"]),
            )[:5]
        tl.append(
            {
                "bucket": label,
                "count": meta_ctx["tl_counts"][b],
                "avg_compound": round(
                    meta_ctx["tl_sum"][b] / max(meta_ctx["tl_counts"][b], 1), 4
                ),
                "top_drivers": top,
            }
        )
    return tl


def _infer_bucket_series(df, date_cfg):
    _ensure_pd_np()
    grp = None
    date_col = None

    # parse cfg
    if date_cfg and not isinstance(date_cfg, dict):
        try:
            date_cfg = json.loads(date_cfg)
            msg = _PL_normalize_filter(msg)  # keep legacy no-op; guarded by try
        except Exception:
            date_cfg = None

    # choose date column
    if date_cfg and date_cfg.get("column") in df.columns:
        date_col = date_cfg["column"]
    else:
        date_col = _detect_date_column(df)

    # no date column → nothing to bucket, but KEEP rows
    if not date_col:
        df["__dt"] = pd.NaT
        df["__bucket"] = None
        return df, "D", None

    # parse dates (keep invalids as NaT)
    s = pd.to_datetime(
        df[date_col], errors="coerce", utc=True, infer_datetime_format=True
    ).dt.normalize()
    df["__dt"] = s
    mask_dt = df["__dt"].notna()

    # optional RANGE filter: apply only to rows that actually have dates
    if date_cfg:
        start = (
            pd.to_datetime(date_cfg.get("start"), utc=True, errors="coerce")
            if date_cfg.get("start")
            else None
        )
        end = (
            pd.to_datetime(date_cfg.get("end"), utc=True, errors="coerce")
            if date_cfg.get("end")
            else None
        )
        if start is not None:
            df.loc[mask_dt & (df["__dt"] < start.normalize()), "__dt"] = pd.NaT
        if end is not None:
            df.loc[mask_dt & (df["__dt"] > end.normalize()), "__dt"] = pd.NaT

    # preferred grouping: date_cfg.group > env > daily
    preferred = None
    if isinstance(date_cfg, dict):
        g = str(date_cfg.get("group", "")).upper()
        if g in {"D", "W", "M"}:
            preferred = g
    if not preferred:
        preferred = PL_TIMELINE_GROUP
    grp = preferred or "D"

    # --- NEW: auto-upscale to monthly for long spans (>= 365 days) unless explicitly set ---
    valid_dt = df.loc[mask_dt, "__dt"].dropna()
    if not (isinstance(date_cfg, dict) and date_cfg.get("group")):
        try:
            if not valid_dt.empty:
                span_days = int((valid_dt.max() - valid_dt.min()).days)
                if span_days >= 365:
                    grp = "M"
        except Exception:
            pass

    # bucket only rows with valid dates; others stay None
    df["__bucket"] = None
    if not valid_dt.empty:
        if grp == "M":
            df.loc[mask_dt, "__bucket"] = df.loc[mask_dt, "__dt"].dt.to_period("M")
        elif grp == "W":
            df.loc[mask_dt, "__bucket"] = df.loc[mask_dt, "__dt"].dt.to_period("W-MON")
            grp = "W"
        else:
            grp = "D"
            df.loc[mask_dt, "__bucket"] = df.loc[mask_dt, "__dt"].dt.to_period("D")

    return df, grp, date_col


def _results_iter_with_meta(
    df,
    selected_columns: List[str],
    merge_text: bool,
    model_choice: str,
    template,
    filt,
    explain: bool,
    grp: Optional[str] = None,
):
    """
    Generator that yields each record AND accumulates meta along the way.
    Also yields a final ('__meta__', meta_obj) sentinel at the end.
    """
    meta_ctx = {
        "kw_comps": {},
        "tl_counts": {},
        "tl_sum": {},
        "drivers": {},  # ← ensure drivers table exists (fixes STREAM FAIL: 'drivers')
    }
    if explain:
        meta_ctx["tl_drivers"] = {}

    for rec, clean_text in _results_iter(
        df, selected_columns, merge_text, model_choice, template, filt, explain
    ):
        b = None
        try:
            b = str(rec.get("__bucket")) if rec.get("__bucket") is not None else None
        except Exception:
            b = None

        # ALWAYS have a drivers field to avoid KeyError downstream
        drivers = rec.get("drivers", []) if explain else []
        if drivers is None:
            drivers = []
        if explain and "drivers" not in rec:
            rec["drivers"] = drivers

        _accumulate_meta(meta_ctx, clean_text, rec.get("compound", 0.0), drivers, b)
        yield rec

    def _avg(v):
        if isinstance(v, tuple) and len(v) == 2:
            s, c = v
            return s / (c or 1)
        if isinstance(v, list):
            return sum(v) / (len(v) or 1)
        return float(v)

    kw_list = _finalize_keywords(meta_ctx["kw_comps"])
    kw_agg = {w: [s, c] for w, (s, c) in meta_ctx["kw_comps"].items()}

    timeline = _timeline_from_meta(meta_ctx, grp)
    drivers_summary = sorted(
        [
            {"phrase": p, "kind": k, "count": v["count"], "delta": v["delta"]}
            for (p, k), v in meta_ctx.get("drivers", {}).items()
        ],
        key=lambda x: -abs(x["delta"]),
    )[:20]

    meta_obj = {"timeline": timeline}
    if explain:
        meta_obj["drivers_summary"] = drivers_summary

    # NEW: lightweight events so the UI has something to render
    events = []
    if timeline:
        # always include a simple timeline event
        events.append({"type": "timeline", "buckets": len(timeline)})

        # best / worst buckets as events (optional but useful)
        try:
            best = max(timeline, key=lambda b: float(b.get("avg_compound", 0.0)))
            worst = min(timeline, key=lambda b: float(b.get("avg_compound", 0.0)))
            events.append(
                {
                    "type": "best_bucket",
                    "bucket": best.get("bucket"),
                    "avg": float(best.get("avg_compound", 0.0)),
                    "count": int(best.get("count", 0)),
                }
            )
            events.append(
                {
                    "type": "worst_bucket",
                    "bucket": worst.get("bucket"),
                    "avg": float(worst.get("avg_compound", 0.0)),
                    "count": int(worst.get("count", 0)),
                }
            )
        except Exception:
            pass

    yield "__meta__", {
        "keywords_comp": kw_list,
        "kw_agg": kw_agg,
        "events": events,  # ← emit events here
        "meta": meta_obj,
    }


# ───────────────────────────────────────────────────────────────
# Post ID detection + Top posts
# ───────────────────────────────────────────────────────────────
POST_ID_CANDIDATES = [
    "post_id",
    "postid",
    "parent_id",
    "parentid",
    "thread_id",
    "threadid",
    "conversation_id",
    "conversationid",
    "submission_id",
    "link_id",
    "tweet_id",
    "status_id",
]


def _detect_post_id_column(df, explicit: Optional[str] = None) -> Optional[str]:
    """Choose post id column: explicit > env > name hints > duplication heuristic."""
    if explicit and explicit in df.columns:
        return explicit
    env_col = os.getenv("PL_POST_ID_COL")
    if env_col and env_col in df.columns:
        return env_col
    # name hints
    for c in df.columns:
        if str(c).strip().lower() in POST_ID_CANDIDATES:
            return c
    # duplication heuristic: prefer object/int-like with biggest duplicate mass
    best, best_mass = None, 0
    for c in df.columns:
        try:
            s = df[c]
            if getattr(s, "dtype", None) is not None and s.dtype.kind not in (
                "O",
                "i",
                "u",
                "U",
                "S",
            ):  # object/int/str
                continue
            vc = s.astype(str).fillna("").value_counts()
            dup_mass = int(vc[vc > 1].sum())
            if dup_mass > best_mass:
                best, best_mass = c, dup_mass
        except Exception:
            continue
    return best if best_mass >= 2 else None


def _detect_post_id_in_records(
    records: List[Dict[str, Any]], explicit: Optional[str] = None
) -> Optional[str]:
    """Same as above but for a list of dict rows (streaming synopsis buffer)."""
    if not records:
        return None
    keys = list(records[0].keys())

    if explicit and explicit in keys:
        return explicit
    env_col = os.getenv("PL_POST_ID_COL")
    if env_col and env_col in keys:
        return env_col
    # name hints
    for k in keys:
        if str(k).strip().lower() in POST_ID_CANDIDATES:
            return k
    # duplication mass
    best, best_mass = None, 0
    for k in keys:
        try:
            counts: Dict[str, int] = {}
            for r in records:
                v = r.get(k)
                if v is None or v == "":
                    continue
                vv = str(v)
                counts[vv] = counts.get(vv, 0) + 1
            dup_mass = sum(c for c in counts.values() if c > 1)
            if dup_mass > best_mass:
                best, best_mass = k, dup_mass
        except Exception:
            continue
    return best if best_mass >= 2 else None


def _summarize_top_posts(
    rows: List[Dict[str, Any]], post_col: Optional[str], topn: int = 5
):
    """Return three lists: most_discussed, most_negative, most_positive (id,count,avg)."""
    if not post_col:
        return [], [], []
    agg: Dict[str, Dict[str, Any]] = {}
    for r in rows:
        pid = r.get(post_col)
        if pid is None or pid == "":  # skip empties
            continue
        pid = str(pid)
        a = agg.setdefault(pid, {"count": 0, "sum": 0.0})
        a["count"] += 1
        a["sum"] += float(r.get("compound", 0.0))
    items = []
    for pid, a in agg.items():
        if a["count"] < 2:  # only duplicates count as “posts”
            continue
        avg = a["sum"] / a["count"]
        items.append((pid, a["count"], avg))
    items.sort(key=lambda x: (-x[1], -abs(x[2])))  # by volume, then extremity
    most_discussed = items[:topn]
    negs = sorted(items, key=lambda x: (x[2], -x[1]))[:topn]
    poss = sorted(items, key=lambda x: (-x[2], -x[1]))[:topn]
    return most_discussed, negs, poss


def _clean_phrase_regex(p: str) -> str:
    # Remove boundary lookarounds and escapes for nicer display
    s = p.replace("(?<!\\w)", "").replace("(?!\\w)", "")
    s = re.sub(r"\\([^\w])", r"\1", s)
    return s.strip()


def _split_overall_drivers(
    meta_obj: Dict[str, Any], topn: int = 10
) -> Tuple[List[str], List[str]]:
    """Return (pos_list, neg_list) of phrases with counts and impact from meta drivers_summary."""
    pos, neg = [], []
    ds = meta_obj.get("drivers_summary", []) if isinstance(meta_obj, dict) else []
    if not ds:
        return pos, neg
    ds_sorted = sorted(ds, key=lambda x: -abs(float(x.get("delta", 0.0))))
    for d in ds_sorted:
        phrase = _clean_phrase_regex(str(d.get("phrase", "")))
        delta = float(d.get("delta", 0.0))
        count = int(d.get("count", 0))
        line = f"'{phrase}'  (x{count}, {delta:+.2f})"
        if delta >= 0:
            pos.append(line)
        else:
            neg.append(line)
    return pos[:topn], neg[:topn]


# ───────────────────────────────────────────────────────────────
# Synopsis builder (+ Overall Drivers + Top Posts)
# ───────────────────────────────────────────────────────────────
def _synopsis_from_rows_and_meta(
    out_rows: List[Dict[str, Any]],
    meta_obj: Dict[str, Any],
    post_id_col: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Robust synopsis with: overall, correct trend cadence (D/W/M),
    best/worst bucket with Δ vs prior, short-term slope, since-last-period deltas,
    WHY drivers (from keywords_comp), hot posts, coverage/caveats, and concrete actionables.
    """
    _ensure_pd_np()

    # --- Basic tallies
    n = len(out_rows)
    avg = (
        round(sum(float(r.get("compound", 0.0)) for r in out_rows) / max(n, 1), 3)
        if n
        else 0.0
    )
    posc = sum(1 for r in out_rows if r.get("final_sentiment") == "POSITIVE")
    neuc = sum(1 for r in out_rows if r.get("final_sentiment") == "NEUTRAL")
    negc = sum(1 for r in out_rows if r.get("final_sentiment") == "NEGATIVE")

    # --- Timeline & helpers
    tl = meta_obj.get("timeline") or []

    def _parse_bucket_label(b):
        try:
            return pd.to_datetime(str(b.get("bucket")), errors="coerce", utc=True)
        except Exception:
            return pd.NaT

    tl_sorted = [
        dict(b)
        for b in sorted(tl, key=_parse_bucket_label)
        if "avg_compound" in b and "count" in b
    ]

    def _fmt_date_ymd(d):
        try:
            return pd.to_datetime(d, errors="coerce", utc=True).strftime("%Y-%m-%d")
        except Exception:
            return str(d)

    # Cadence detection (median gap between buckets, in days)
    def _cadence_days(buckets):
        ds = [_parse_bucket_label(b) for b in buckets]
        ds = [d for d in ds if pd.notna(d)]
        if len(ds) < 2:
            return None
        diffs = []
        for i in range(1, len(ds)):
            try:
                dd = (ds[i] - ds[i - 1]).total_seconds() / 86400.0
            except Exception:
                continue
            diffs.append(abs(float(dd)))
        if not diffs:
            return None
        return float(pd.Series(diffs).median())

    def _gran_from_cadence(c_days: Optional[float]) -> str:
        if c_days is None:
            return "period-over-period"
        if c_days <= 1.5:
            return "day-over-day"
        if c_days <= 10.0:
            return "week-over-week"
        return "month-over-month"

    # NEW: total span days to decide YoY labeling
    def _total_span_days(buckets):
        ds = [_parse_bucket_label(b) for b in buckets]
        ds = [d for d in ds if pd.notna(d)]
        if len(ds) < 2:
            return None
        return int((max(ds) - min(ds)).total_seconds() / 86400.0)

    def _fmt_bucket_label(raw, c_days: Optional[float]):
        try:
            dt = pd.to_datetime(raw, errors="coerce", utc=True)
        except Exception:
            return str(raw)
        if pd.isna(dt):
            return str(raw)
        if c_days is not None and c_days > 10.0:
            return dt.strftime("%Y-%m")  # monthly view
        return dt.strftime("%Y-%m-%d")  # daily/weekly view

    def _best_worst_and_deltas(buckets, c_days):
        # returns (best, worst) where item = (label, avg, count, delta_vs_prior)
        out = []
        for i, b in enumerate(buckets):
            label = _fmt_bucket_label(b.get("bucket"), c_days)
            avgv = float(b.get("avg_compound", 0.0))
            cnt = int(b.get("count", 0))
            dvp = None
            if i > 0:
                av_prev = float(buckets[i - 1].get("avg_compound", 0.0))
                dvp = round(avgv - av_prev, 3)
            out.append((label, round(avgv, 3), cnt, dvp))
        if not out:
            return None, None
        best = max(out, key=lambda x: x[1])
        worst = min(out, key=lambda x: x[1])
        return best, worst

    c_days = _cadence_days(tl_sorted)
    total_days = _total_span_days(tl_sorted)
    best, worst = _best_worst_and_deltas(tl_sorted, c_days)

    # short-term slope over last 3 buckets
    slope = None
    if len(tl_sorted) >= 3:
        a0 = float(tl_sorted[-3]["avg_compound"])
        a2 = float(tl_sorted[-1]["avg_compound"])
        slope = round((a2 - a0) / 2.0, 3)

    # Since-last-period comparison: split timeline in half
    def _avg_of_range(items):
        if not items:
            return 0.0
        s, c = 0.0, 0
        for it in items:
            s += float(it.get("avg_compound", 0.0)) * int(it.get("count", 0))
            c += int(it.get("count", 0))
        return (s / c) if c else 0.0

    prev_avg = cur_avg = None
    neg_share_prev = neg_share_cur = None
    if len(tl_sorted) >= 4:
        mid = len(tl_sorted) // 2
        prev, cur = tl_sorted[:mid], tl_sorted[mid:]
        prev_avg = round(_avg_of_range(prev), 3)
        cur_avg = round(_avg_of_range(cur), 3)

        # compute neg share by mapping rows to halves via __bucket
        def _set_of_labels(items):
            return set(_fmt_date_ymd(b.get("bucket")) for b in items)

        prev_labels, cur_labels = _set_of_labels(prev), _set_of_labels(cur)

        def _neg_share(lbls):
            if not out_rows:
                return 0.0

            # bucket label in out_rows is stringified Period; normalize to %Y-%m-%d prefix if present
            def _norm(v):
                s = str(v)
                return s[:10] if re.match(r"^\d{4}-\d{2}-\d{2}", s) else s

            rel = [
                r
                for r in out_rows
                if r.get("__bucket") is not None and _norm(r.get("__bucket")) in lbls
            ]
            if not rel:
                return 0.0
            nneg = sum(1 for r in rel if r.get("final_sentiment") == "NEGATIVE")
            return (nneg * 100.0) / len(rel)

        neg_share_prev = round(_neg_share(prev_labels), 1)
        neg_share_cur = round(_neg_share(cur_labels), 1)

    # Token drivers (from keywords_comp)
    kw = meta_obj.get("keywords_comp") or []
    pos_tokens = [d for d in kw if float(d.get("compound", 0)) > 0]
    neg_tokens = [d for d in kw if float(d.get("compound", 0)) < 0]
    pos_tokens_sorted = sorted(
        pos_tokens, key=lambda x: float(x.get("compound", 0)), reverse=True
    )[:5]
    neg_tokens_sorted = sorted(neg_tokens, key=lambda x: float(x.get("compound", 0)))[
        :5
    ]

    # Hot posts
    most_discussed, most_negative, most_positive = _summarize_top_posts(
        out_rows, post_id_col, topn=5
    )

    # Coverage & caveats
    with_dt = sum(1 for r in out_rows if r.get("__dt") is not None)
    pct_dt = int(round((with_dt * 100.0) / max(n, 1)))
    min_bucket = min((int(b.get("count", 0)) for b in tl_sorted), default=0)

    # Build synopsis text
    lines = []
    line = "═" * 80
    lines += [
        line,
        "COMPREHENSIVE SENTIMENT ANALYSIS REPORT",
        line,
        "",
        "EXECUTIVE SUMMARY",
        "─" * 80,
        "",
    ]
    lines.append(
        f"Analyzed {n} rows. Overall sentiment {avg:+.3f} ({posc} positive / {neuc} neutral / {negc} negative)."
    )

    # Trend (cadence-aligned) — label YoY when span >= 1 year
    if tl_sorted:
        gran_base = _gran_from_cadence(c_days)
        if (c_days is not None and c_days > 10.0) and (
            total_days is not None and total_days >= 365
        ):
            gran = "year-over-year"
        else:
            gran = gran_base
        lines += ["", f"TREND ({gran})", "─" * 80, ""]
        if best:
            b_lbl, b_avg, b_n, b_dvp = best
            lines.append(
                f"Best bucket: {b_lbl} — {b_avg:+.3f}"
                + (f" (Δ vs prior {b_dvp:+.3f})" if b_dvp is not None else "")
            )
        if worst:
            w_lbl, w_avg, w_n, w_dvp = worst
            lines.append(
                f"Worst bucket: {w_lbl} — {w_avg:+.3f}"
                + (f" (Δ vs prior {w_dvp:+.3f})" if w_dvp is not None else "")
            )
        if slope is not None:
            lines.append(f"Recent slope (last 3 buckets): {slope:+.3f} per bucket")

    # Optional YoY (only for ~monthly cadence with enough history)
    if c_days is not None and c_days > 10.0 and len(tl_sorted) >= 13:
        try:
            last = tl_sorted[-1]
            last_dt = _parse_bucket_label(last.get("bucket"))
            if pd.notna(last_dt):
                target = last_dt - pd.DateOffset(years=1)

                def _dist(b):
                    d = _parse_bucket_label(b.get("bucket"))
                    return abs((d - target).days) if pd.notna(d) else 10**9

                prev_year = min(tl_sorted[:-1], key=_dist)
                yoy = float(last.get("avg_compound", 0.0)) - float(
                    prev_year.get("avg_compound", 0.0)
                )
                lines += ["", "YEAR-OVER-YEAR", "─" * 80, ""]
                lines.append(
                    f"YoY Δ: {yoy:+.3f}  (current {_fmt_bucket_label(last.get('bucket'), c_days)} vs "
                    f"prior year {_fmt_bucket_label(prev_year.get('bucket'), c_days)})"
                )
        except Exception:
            pass

    # Since last period (split timeline)
    if prev_avg is not None and cur_avg is not None:
        lines += ["", "SINCE LAST PERIOD", "─" * 80, ""]
        lines.append(
            f"Avg sentiment Δ: {cur_avg - prev_avg:+.3f} (prev {prev_avg:+.3f} → current {cur_avg:+.3f})"
        )
        if neg_share_prev is not None and neg_share_cur is not None:
            lines.append(
                f"Negative share Δ: {neg_share_cur - neg_share_prev:+.1f}pp (prev {neg_share_prev:.1f}% → current {neg_share_cur:.1f}%)"
            )

    # WHY (drivers)
    if pos_tokens_sorted or neg_tokens_sorted:
        lines += ["", "WHY (Top drivers — Top 5 each)", "─" * 80, ""]
        if pos_tokens_sorted:
            lines.append("Positive:")
            for d in pos_tokens_sorted:
                lines.append(
                    f"• {d.get('word','')}  (impact {float(d.get('compound',0)):+.2f})"
                )
        if neg_tokens_sorted:
            if pos_tokens_sorted:
                lines.append("")
            lines.append("Negative:")
            for d in neg_tokens_sorted:
                lines.append(
                    f"• {d.get('word','')}  (impact {float(d.get('compound',0)):+.2f})"
                )

    # Hot posts
    if post_id_col and (most_discussed or most_negative or most_positive):
        lines += ["", "HOT POSTS TO REVIEW", "─" * 80, ""]
        if most_negative:
            lines.append("Most negative avg sentiment:")
            for pid, cnt, a in most_negative:
                lines.append(f"• {pid}  (n={cnt}, avg={a:+.3f})")
        if most_discussed:
            lines.append("")
            lines.append("Most discussed:")
            for pid, cnt, a in most_discussed:
                lines.append(f"• {pid}  (n={cnt}, avg={a:+.3f})")

    # Coverage & caveats
    lines += ["", "COVERAGE & CAVEATS", "─" * 80, ""]
    lines.append(
        f"Valid dates: {pct_dt}% of rows; timeline buckets: {len(tl_sorted)}; min bucket size: {min_bucket}."
    )
    if min_bucket < 25 and len(tl_sorted) > 0:
        lines.append(
            "Note: Buckets with <25 rows may yield noisy trends; treat small-bucket deltas with caution."
        )
    if meta_obj.get("date_filter_applied"):
        lines.append("Date filter applied: results reflect the specified window only.")

    # Actionables (tie to data)
    actions = []
    # 1) Worst bucket + negative tokens
    if worst and neg_tokens_sorted:
        w_lbl, w_avg, _, _ = worst
        neg_names = ", ".join(d.get("word", "") for d in neg_tokens_sorted[:3])
        actions.append(f"Focus on {w_lbl} (avg {w_avg:+.3f}); address {neg_names}.")
    # 2) Slope direction
    if slope is not None and abs(slope) >= 0.02:
        if slope < 0:
            actions.append(
                "Reverse recent downward slope via fast triage on top negative tokens, then re-measure next bucket."
            )
        else:
            actions.append(
                "Amplify positive momentum; continue what’s working from the Top Positive Drivers."
            )
    # 3) Hot posts for triage
    if most_negative:
        ids = ", ".join(pid for pid, _, _ in most_negative[:3])
        actions.append(f"Triage threads: {ids} (worst average sentiment).")

    if actions:
        lines += ["", "ACTIONABLES", "─" * 80, ""]
        for a in actions[:3]:
            lines.append(f"• {a}")

    # Summary line for UI
    summary = f"Analyzed {n} rows. Overall: {avg:+.3f}. {posc} positive, {neuc} neutral, {negc} negative."

    # Structured extras for UI/PDF (keep original contract)
    top_posts = {
        "column": post_id_col,
        "most_discussed": most_discussed,
        "most_negative": most_negative,
        "most_positive": most_positive,
    }
    # Keep top_drivers field (now based on tokens table already injected by rewriter)
    pos_list = [
        f"'{d.get('word','')}'  (x—, {float(d.get('compound',0)):+.2f})"
        for d in pos_tokens_sorted
    ]
    neg_list = [
        f"'{d.get('word','')}'  (x—, {float(d.get('compound',0)):+.2f})"
        for d in neg_tokens_sorted
    ]
    top_drivers = {"positive": pos_list, "negative": neg_list}

    full_report = "\n".join(lines)
    return {
        "synopsis": _pl_rewrite_synopsis(full_report, {"keywords_comp": kw}),
        "synopsis_summary": summary,
        "top_posts": top_posts,
        "top_drivers": top_drivers,
    }


# ─
# ───────────────────────────────────────────────────────────────
# PDF writer (optional)
# ───────────────────────────────────────────────────────────────
def _write_pdf_report(
    pdf_path: str,
    title: str,
    synopsis_text: str,
    top_drivers: Dict[str, List[str]],
    top_posts: Dict[str, Any],
) -> Tuple[bool, str]:
    """
    Try to write a nicely formatted PDF with Title/H1/H2. Returns (ok, path_or_msg).
    """
    if not pdf_path:
        return False, "no path"
    try:
        # Try ReportLab first
        from reportlab.lib.pagesizes import LETTER
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        from reportlab.lib.units import inch
        from reportlab.platypus import (
            SimpleDocTemplate,
            Paragraph,
            Spacer,
            ListFlowable,
            ListItem,
        )

        doc = SimpleDocTemplate(
            pdf_path,
            pagesize=LETTER,
            leftMargin=0.9 * inch,
            rightMargin=0.9 * inch,
            topMargin=0.9 * inch,
            bottomMargin=0.9 * inch,
        )
        styles = getSampleStyleSheet()
        styles.add(ParagraphStyle(name="H1", parent=styles["Heading1"], spaceAfter=12))
        styles.add(ParagraphStyle(name="H2", parent=styles["Heading2"], spaceAfter=8))
        styles.add(ParagraphStyle(name="Body", parent=styles["BodyText"], leading=14))

        flow = []
        flow.append(Paragraph(title, styles["Title"]))
        flow.append(Spacer(1, 12))

        # Executive Summary + rest of synopsis paragraphs
        flow.append(Paragraph("Executive Summary", styles["H1"]))
        for para in synopsis_text.splitlines():
            para = para.strip()
            if not para:
                flow.append(Spacer(1, 6))
                continue
            # Convert section headings heuristically
            if para.isupper() and len(para) < 60:
                flow.append(Paragraph(para.title(), styles["H2"]))
            elif para.startswith("• "):
                items = []
                items.append(ListItem(Paragraph(para[2:], styles["Body"])))
                flow.append(ListFlowable(items, bulletType="bullet"))
            else:
                flow.append(Paragraph(para, styles["Body"]))

        # Overall Drivers
        if top_drivers and (top_drivers.get("positive") or top_drivers.get("negative")):
            flow.append(Spacer(1, 12))
            flow.append(Paragraph("Overall Top Drivers", styles["H1"]))
            if top_drivers.get("positive"):
                flow.append(Paragraph("Positive", styles["H2"]))
                flow.append(
                    ListFlowable(
                        [
                            ListItem(Paragraph(x.replace("• ", ""), styles["Body"]))
                            for x in top_drivers.get("positive", [])
                        ],
                        bulletType="bullet",
                    )
                )
            if top_drivers.get("negative"):
                flow.append(Paragraph("Negative", styles["H2"]))
                flow.append(
                    ListFlowable(
                        [
                            ListItem(Paragraph(x.replace("• ", ""), styles["Body"]))
                            for x in top_drivers.get("negative", [])
                        ],
                        bulletType="bullet",
                    )
                )

        # Top Posts
        if top_posts and (
            top_posts.get("most_discussed")
            or top_posts.get("most_negative")
            or top_posts.get("most_positive")
        ):
            flow.append(Spacer(1, 12))
            flow.append(Paragraph("Top Posts (by duplicate Post ID)", styles["H1"]))
            col = top_posts.get("column")
            if col:
                flow.append(Paragraph(f"Post ID column: {col}", styles["Body"]))

            def _fmt(items):
                return [f"{pid} (n={cnt}, avg={avg:+.3f})" for pid, cnt, avg in items]

            if top_posts.get("most_discussed"):
                flow.append(Paragraph("Most discussed", styles["H2"]))
                flow.append(
                    ListFlowable(
                        [
                            ListItem(Paragraph(x, styles["Body"]))
                            for x in _fmt(top_posts["most_discussed"])
                        ],
                        bulletType="bullet",
                    )
                )
            if top_posts.get("most_negative"):
                flow.append(Paragraph("Most negative avg sentiment", styles["H2"]))
                flow.append(
                    ListFlowable(
                        [
                            ListItem(Paragraph(x, styles["Body"]))
                            for x in _fmt(top_posts["most_negative"])
                        ],
                        bulletType="bullet",
                    )
                )
            if top_posts.get("most_positive"):
                flow.append(Paragraph("Most positive avg sentiment", styles["H2"]))
                flow.append(
                    ListFlowable(
                        [
                            ListItem(Paragraph(x, styles["Body"]))
                            for x in _fmt(top_posts["most_positive"])
                        ],
                        bulletType="bullet",
                    )
                )

        doc.build(flow)
        return True, pdf_path
    except Exception as e1:
        # Fallback: try fpdf
        try:
            from fpdf import FPDF

            pdf = FPDF()
            pdf.set_auto_page_break(auto=True, margin=15)
            pdf.add_page()
            pdf.set_font("Arial", "B", 16)
            pdf.multi_cell(0, 10, title)
            pdf.ln(4)

            def h1(t):
                pdf.set_font("Arial", "B", 14)
                pdf.multi_cell(0, 8, t)
                pdf.ln(2)

            def h2(t):
                pdf.set_font("Arial", "B", 12)
                pdf.multi_cell(0, 7, t)
                pdf.ln(1)

            def body(t):
                pdf.set_font("Arial", "", 11)
                pdf.multi_cell(0, 6, t)

            h1("Executive Summary")
            for para in synopsis_text.splitlines():
                para = para.strip()
                if not para:
                    pdf.ln(2)
                    continue
                if para.isupper() and len(para) < 60:
                    h2(para.title())
                else:
                    body(para)
            if top_drivers and (
                top_drivers.get("positive") or top_drivers.get("negative")
            ):
                pdf.ln(3)
                h1("Overall Top Drivers")
                if top_drivers.get("positive"):
                    h2("Positive")
                    for x in top_drivers.get("positive", []):
                        body(f"• {x}")
                if top_drivers.get("negative"):
                    h2("Negative")
                    for x in top_drivers.get("negative", []):
                        body(f"• {x}")
            if top_posts and (
                top_posts.get("most_discussed")
                or top_posts.get("most_negative")
                or top_posts.get("most_positive")
            ):
                pdf.ln(3)
                h1("Top Posts (by duplicate Post ID)")
                col = top_posts.get("column")
                if col:
                    body(f"Post ID column: {col}")

                def _fmt(items):
                    return [
                        f"{pid} (n={cnt}, avg={avg:+.3f})" for pid, cnt, avg in items
                    ]

                if top_posts.get("most_discussed"):
                    h2("Most discussed")
                    for x in _fmt(top_posts["most_discussed"]):
                        body(f"• {x}")
                if top_posts.get("most_negative"):
                    h2("Most negative avg sentiment")
                    for x in _fmt(top_posts["most_negative"]):
                        body(f"• {x}")
                if top_posts.get("most_positive"):
                    h2("Most positive avg sentiment")
                    for x in _fmt(top_posts["most_positive"]):
                        body(f"• {x}")
            pdf.output(pdf_path)
            return True, pdf_path
        except Exception as e2:
            return False, f"PDF export failed: {e1} | {e2}"


# ───────────────────────────────────────────────────────────────
# Main analysis APIs (with PostID + PDF support)
# ───────────────────────────────────────────────────────────────
def run_sentiment_analysis(
    file_path: str,
    selected_columns: list,
    skip_rows: int,
    merge_text: bool,
    model_choice: str,
    template=None,
    filt=None,
    explain: bool = False,
    date_cfg=None,
    synopsis: bool = False,
    post_id_col_hint: Optional[str] = None,
    pdf_out: Optional[str] = None,
    events: Optional[list] = None,  # UI-passed events (kept for compatibility)
) -> str:
    """
    Main entrypoint for CSV/XLSX analysis.
    Streams JSONL to PL_OUT when set (CSV path), otherwise returns JSON.
    Ensures final meta includes simple 'events' compatible with existing Swift UI.
    """
    _ensure_pd_np()
    _dbg(
        f"run_sentiment_analysis file={file_path} "
        f"cols={selected_columns} skip={skip_rows} merge={merge_text} "
        f"model={model_choice} PL_OUT={os.environ.get('PL_OUT')!r}"
    )
    T(
        f"ANALYZE start file={file_path} cols={selected_columns} skip={skip_rows} merge={merge_text} model={model_choice}"
    )

    # Force rich output
    explain = True
    synopsis = True

    is_xlsx = file_path.lower().endswith(".xlsx")
    chunksize = CHUNKSIZE

    # Helper: make simple Swift-friendly events from a timeline
    def _simple_events_from_timeline(tl):
        ev = []
        try:
            if tl:
                ev.append({"type": "timeline", "buckets": len(tl)})
                best = max(tl, key=lambda b: float(b.get("avg_compound", 0.0)))
                worst = min(tl, key=lambda b: float(b.get("avg_compound", 0.0)))
                ev.append(
                    {
                        "type": "best_bucket",
                        "bucket": best.get("bucket"),
                        "avg": float(best.get("avg_compound", 0.0)),
                        "count": int(best.get("count", 0)),
                    }
                )
                ev.append(
                    {
                        "type": "worst_bucket",
                        "bucket": worst.get("bucket"),
                        "avg": float(worst.get("avg_compound", 0.0)),
                        "count": int(worst.get("count", 0)),
                    }
                )
        except Exception:
            pass
        return ev

    # --- Streaming path (CSV + PL_OUT) ---
    if PL_OUT and not is_xlsx:
        out_path = (
            PL_OUT if os.path.isabs(PL_OUT) else str(Path("/tmp") / "pl_result.jsonl")
        )
        T(
            f"STREAMING path → out={out_path} chunksize={chunksize} progress_every={PL_PROGRESS_EVERY}"
        )

        # Sample to infer timeline grouping
        t0 = _t__.time()
        try:
            sample = pd.read_csv(file_path, nrows=1000, skiprows=skip_rows)
            T(f"SAMPLE read dt={_t__.time()-t0:.2f}s rows={len(sample)}")
        except Exception as e:
            T(f"ERROR sample read: {e}")
            return _dumps(
                {
                    "error": f"read_failed: {e}",
                    "rows": [],
                    "row_headers": [],
                    "keywords_comp": [],
                }
            )

        t1 = _t__.time()
        sample, grp, detected_col = _infer_bucket_series(sample, date_cfg)
        if not grp:
            grp = PL_TIMELINE_GROUP or "D"
        T(
            f"SAMPLE infer_bucket dt={_t__.time()-t1:.2f}s grp={grp} detected={detected_col}"
        )

        # range flag
        has_range = False
        try:
            cfg = (
                json.loads(date_cfg) if isinstance(date_cfg, str) else (date_cfg or {})
            )
            has_range = bool(cfg.get("start") or cfg.get("end"))
        except Exception:
            has_range = False

        orig_cols = list(sample.columns)
        score_cols = [
            "pos",
            "neu",
            "neg",
            "compound",
            "compound_raw",
            "compound_override",
            "compound_effective",
        ]
        model_cols = ["model_label", "model_confidence"]
        extra_cols = ["final_sentiment", "used"] + (
            ["spacy_negation"] if model_choice == "vader" else []
        )
        if "__dt" not in orig_cols:
            orig_cols += ["__dt"]
        if "__bucket" not in orig_cols:
            orig_cols += ["__bucket"]
        if explain and "drivers" not in orig_cols:
            orig_cols += ["drivers"]
        if explain and EMIT_SIGNATURE:
            if "removed_signature" not in orig_cols:
                orig_cols += ["removed_signature"]
            if "removed_handles" not in orig_cols:
                orig_cols += ["removed_handles"]
        headers = orig_cols + score_cols + model_cols + extra_cols

        meta_ctx_global = {
            "kw_comps": {},
            "tl_counts": {},
            "tl_sum": {},
            "drivers": {},
            "tl_drivers": {},
        }
        buffered_rows_for_synopsis: List[Dict[str, Any]] = []
        total_processed = 0
        progress_every = max(1, int(os.environ.get("PL_PROGRESS_EVERY", "100")))
        last_meta = None
        detected_post_id_col_final: Optional[str] = None

        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as f:
            header_stub = {
                "__meta__": True,
                "row_headers": headers,
                "keywords_comp": [],
                "meta": {
                    "status": "initializing",
                    "timeline": [],
                    "unavailable_reasons": [],
                    "detected_date_column": detected_col,
                    "detected_post_id_column": None,
                    "pl_out": out_path,
                    "events": events or [],  # keep initial stub behavior
                },
                "pl_out": out_path,
            }
            f.write(_dumps(header_stub) + "\n")
            f.flush()
            os.fsync(f.fileno())
            T("WROTE header stub")

            try:
                for chunk in pd.read_csv(
                    file_path, chunksize=chunksize, skiprows=skip_rows
                ):
                    t_chunk = _t__.time()
                    T(f"CHUNK read start (target rows≈{chunksize})")

                    eff_cfg = {"group": grp}
                    try:
                        if date_cfg:
                            if isinstance(date_cfg, str):
                                eff_cfg.update(json.loads(date_cfg) or {})
                            elif isinstance(date_cfg, dict):
                                eff_cfg.update(date_cfg)
                    except Exception:
                        pass

                    chunk, _, _ = _infer_bucket_series(chunk, eff_cfg)
                    if has_range and "__dt" in chunk.columns:
                        chunk = chunk.loc[chunk["__dt"].notna()].copy()

                    if detected_post_id_col_final is None:
                        try:
                            detected_post_id_col_final = _detect_post_id_column(
                                chunk, post_id_col_hint
                            )
                        except Exception:
                            detected_post_id_col_final = None

                    T(
                        f"CHUNK infer_bucket dt={_t__.time()-t_chunk:.2f}s rows={len(chunk)}"
                    )
                    last_meta = None

                    t_score = _t__.__time = _t__.time()
                    for item in _results_iter_with_meta(
                        chunk,
                        selected_columns,
                        merge_text,
                        model_choice,
                        template,
                        filt,
                        explain,
                        grp,
                    ):
                        if (
                            isinstance(item, tuple)
                            and len(item) == 2
                            and item[0] == "__meta__"
                        ):
                            last_meta = item[1]
                            continue
                        rec = item
                        try:
                            if explain and "drivers" not in rec:
                                rec["drivers"] = []
                        except Exception:
                            pass
                        try:
                            rec.setdefault("drivers", [])
                        except Exception:
                            pass
                        f.write(_dumps(rec) + "\n")
                        total_processed += 1
                        if synopsis:
                            buffered_rows_for_synopsis.append(rec)
                        if (total_processed % 1000) == 0:
                            f.flush()
                            os.fsync(f.fileno())
                        if (total_processed % progress_every) == 0:
                            hb = {
                                "__meta__": True,
                                "meta": {
                                    "status": "running",
                                    "processed": total_processed,
                                },
                            }
                            f.write(_dumps(hb) + "\n")
                            f.flush()
                            os.fsync(f.fileno())
                            T(f"HEARTBEAT processed={total_processed}")

                    T(
                        f"CHUNK score/write dt={_t__.time()-t_score:.2f}s emitted_total={total_processed}"
                    )

                    if last_meta:
                        if "kw_agg" in last_meta:
                            for w, pair in last_meta["kw_agg"].items():
                                s_add, c_add = float(pair[0]), int(pair[1])
                                s0, c0 = meta_ctx_global["kw_comps"].get(w, (0.0, 0))
                                meta_ctx_global["kw_comps"][w] = (
                                    s0 + s_add,
                                    c0 + c_add,
                                )
                        else:
                            for kw in last_meta.get("keywords_comp", []):
                                w = kw["word"]
                                comp = float(kw["compound"])
                                s0, c0 = meta_ctx_global["kw_comps"].get(w, (0.0, 0))
                                meta_ctx_global["kw_comps"][w] = (s0 + comp, c0 + 1)

                        for d in last_meta["meta"].get("drivers_summary", []):
                            k = (d["phrase"], d["kind"])
                            cur = meta_ctx_global["drivers"].get(
                                k, {"count": 0, "delta": 0.0}
                            )
                            meta_ctx_global["drivers"][k] = {
                                "count": cur["count"] + d["count"],
                                "delta": round(cur["delta"] + d["delta"], 3),
                            }

                        for b in last_meta["meta"].get("timeline", []):
                            bucket = b["bucket"]
                            meta_ctx_global["tl_counts"][bucket] = (
                                meta_ctx_global["tl_counts"].get(bucket, 0) + b["count"]
                            )
                            meta_ctx_global["tl_sum"][bucket] = meta_ctx_global[
                                "tl_sum"
                            ].get(bucket, 0.0) + float(b["avg_compound"] * b["count"])

                    _dbg(
                        f"chunk_done rows={len(chunk)} total_emitted={total_processed}"
                    )
                    T(
                        f"CHUNK done dt={_t__.time()-t_chunk:.2f}s total_emitted={total_processed}"
                    )
                    f.flush()
                    os.fsync(f.fileno())

            except Exception as e:
                _dbg(f"stream_fail: {e}")
                T(f"STREAM FAIL: {e}")
            finally:
                final_keywords = _apply_template_overrides_to_kwlist(
                    _finalize_keywords(meta_ctx_global["kw_comps"]), template
                )
                final_timeline = _timeline_from_meta(meta_ctx_global, grp)
                drivers_summary = sorted(
                    [
                        {
                            "phrase": p,
                            "kind": k,
                            "count": v["count"],
                            "delta": v["delta"],
                        }
                        for (p, k), v in meta_ctx_global["drivers"].items()
                    ],
                    key=lambda x: -abs(x["delta"]),
                )[:20]

                if synopsis and buffered_rows_for_synopsis:
                    detected_post_id_col_final = _detect_post_id_in_records(
                        buffered_rows_for_synopsis,
                        detected_post_id_col_final or post_id_col_hint,
                    )

                # >>> FIX: compute Swift-friendly events from final_timeline
                computed_events = _simple_events_from_timeline(final_timeline)

                meta_obj = {
                    "timeline": final_timeline,
                    "status": "final",
                    "unavailable_reasons": [],
                    "processed": total_processed,
                    "detected_date_column": detected_col,
                    "detected_post_id_column": detected_post_id_col_final,
                    "pl_out": out_path,
                    "date_filter_applied": bool(has_range),
                    "drivers_summary": drivers_summary,
                    "events": computed_events,  # <<< use computed events
                }

                if synopsis:
                    meta_obj["keywords_comp"] = final_keywords
                    syn_pack = _synopsis_from_rows_and_meta(
                        buffered_rows_for_synopsis, meta_obj, detected_post_id_col_final
                    )
                    meta_obj.update(
                        {
                            "synopsis": _pl_rewrite_synopsis(
                                syn_pack["synopsis"], {"keywords_comp": final_keywords}
                            ),
                            "synopsis_summary": syn_pack["synopsis_summary"],
                            "top_posts": syn_pack["top_posts"],
                            "top_drivers": syn_pack["top_drivers"],
                        }
                    )
                    final_pdf = pdf_out or PL_PDF_OUT
                    if final_pdf:
                        ok, path_or_msg = _write_pdf_report(
                            final_pdf,
                            "Comprehensive Sentiment Analysis Report",
                            meta_obj.get("synopsis", ""),
                            meta_obj.get("top_drivers", {}),
                            meta_obj.get("top_posts", {}),
                        )
                        if ok:
                            meta_obj["pdf_out"] = path_or_msg
                        else:
                            meta_obj["pdf_error"] = path_or_msg

                top_pos = [
                    d.get("word", "")
                    for d in sorted(
                        final_keywords, key=lambda x: x.get("compound", 0), reverse=True
                    )
                    if d.get("compound", 0) > 0
                ][:10]
                top_neg = [
                    d.get("word", "")
                    for d in sorted(final_keywords, key=lambda x: x.get("compound", 0))
                    if d.get("compound", 0) < 0
                ][:10]
                meta_obj["top_keywords"] = {"positive": top_pos, "negative": top_neg}

                final_meta_obj = {
                    "__meta__": True,
                    "row_headers": headers,
                    "keywords_comp": final_keywords,
                    "meta": meta_obj,
                    "pl_out": out_path,
                }
                f.write(_dumps(final_meta_obj) + "\n")
                f.flush()
                os.fsync(f.fileno())
                try:
                    meta_obj.pop("top_drivers", None)
                    meta_obj.pop("drivers_summary", None)
                except Exception:
                    pass
                T("WROTE final meta")

        return _dumps({"streamed": True, "out_path": out_path})

    # --- Non-streaming path ---
    t_read = _t__.time()
    try:
        if is_xlsx:
            df = pd.read_excel(file_path, skiprows=skip_rows)
        else:
            df = pd.read_csv(file_path, skiprows=skip_rows)
    except Exception as e:
        T(f"ERROR full read: {e}")
        return _dumps(
            {
                "error": f"read_failed: {e}",
                "rows": [],
                "row_headers": [],
                "keywords_comp": [],
            }
        )
    T(f"CSV full read ok dt={_t__.time()-t_read:.2f}s rows={len(df)}")

    t_df_all = _t__.time()
    df, grp, detected_col = _infer_bucket_series(
        df, date_cfg if date_cfg else {"group": PL_TIMELINE_GROUP}
    )
    if not grp:
        grp = PL_TIMELINE_GROUP or "D"
    try:
        cfg = json.loads(date_cfg) if isinstance(date_cfg, str) else (date_cfg or {})
        if (cfg.get("start") or cfg.get("end")) and "__dt" in df.columns:
            df = df.loc[df["__dt"].notna()].copy()
    except Exception:
        pass
    T(
        f"DATE_FILTER(full) dt={_t__.time()-t_df_all:.2f}s rows={len(df)} grp={grp} detected={detected_col}"
    )

    orig_cols = list(df.columns)
    score_cols = [
        "pos",
        "neu",
        "neg",
        "compound",
        "compound_raw",
        "compound_override",
        "compound_effective",
    ]
    model_cols = ["model_label", "model_confidence"]
    extra_cols = ["final_sentiment", "used"] + (
        ["spacy_negation"] if model_choice == "vader" else []
    )
    if "__dt" not in orig_cols:
        orig_cols += ["__dt"]
    if "__bucket" not in orig_cols:
        orig_cols += ["__bucket"]
    if explain and "drivers" not in orig_cols:
        orig_cols += ["drivers"]
    if explain and EMIT_SIGNATURE:
        if "removed_signature" not in orig_cols:
            orig_cols += ["removed_signature"]
        if "removed_handles" not in orig_cols:
            orig_cols += ["removed_handles"]
    headers = orig_cols + score_cols + model_cols + extra_cols

    detected_post_id_col = _detect_post_id_column(df, post_id_col_hint)

    out_rows: List[Dict[str, Any]] = []
    kw_list: List[Dict[str, Any]] = []
    meta_final = {}
    t_score_all = _t__.time()
    for item in _results_iter_with_meta(
        df, selected_columns, merge_text, model_choice, template, filt, explain, grp
    ):
        if isinstance(item, tuple) and len(item) == 2 and item[0] == "__meta__":
            meta_pack = item[1]
            kw_list = meta_pack["keywords_comp"]
            meta_final = meta_pack["meta"]
        else:
            try:
                if explain and "drivers" not in item:
                    item["drivers"] = []
            except Exception:
                pass
            try:
                item.setdefault("drivers", [])
            except Exception:
                pass
            out_rows.append(item)
    T(f"SCORING dt={_t__.time()-t_score_all:.2f}s total_rows={len(out_rows)}")

    # Apply template overrides to keywords_comp before synopsis/top_keywords
    kw_list = _apply_template_overrides_to_kwlist(kw_list, template)

    if synopsis:
        meta_final["keywords_comp"] = kw_list
        syn = _synopsis_from_rows_and_meta(out_rows, meta_final, detected_post_id_col)
        meta_final.update(syn)

    # >>> FIX: compute Swift-friendly events from FINAL timeline (ignore param)
    meta_final["events"] = _simple_events_from_timeline(
        meta_final.get("timeline") or []
    )

    final_pdf = pdf_out or PL_PDF_OUT
    if final_pdf:
        ok, path_or_msg = _write_pdf_report(
            final_pdf,
            "Comprehensive Sentiment Analysis Report",
            meta_final.get("synopsis", ""),
            meta_final.get("top_drivers", {}),
            meta_final.get("top_posts", {}),
        )
        if ok:
            meta_final["pdf_out"] = path_or_msg
        else:
            meta_final["pdf_error"] = path_or_msg

    top_pos = [
        d.get("word", "")
        for d in sorted(kw_list, key=lambda x: x.get("compound", 0), reverse=True)
        if d.get("compound", 0) > 0
    ][:10]
    top_neg = [
        d.get("word", "")
        for d in sorted(kw_list, key=lambda x: x.get("compound", 0))
        if d.get("compound", 0) < 0
    ][:10]
    meta_final["top_keywords"] = {"positive": top_pos, "negative": top_neg}

    return _dumps(
        {
            "rows": out_rows,
            "row_headers": headers,
            "keywords_comp": kw_list,
            "meta": meta_final,
            "detected_date_column": detected_col,
            "detected_post_id_column": detected_post_id_col,
        }
    )


def run_keywords_only(
    file_path: str,
    selected_columns: list,
    skip_rows: int,
    merge_text: bool,
    model_choice: str,
    template=None,
    filt=None,
) -> str:
    """
    Lightweight mode: only outputs keyword-compound averages, no per-row scoring.
    """
    _ensure_pd_np()
    try:
        if file_path.lower().endswith(".xlsx"):
            df = pd.read_excel(file_path, skiprows=skip_rows)
        else:
            df = pd.read_csv(file_path, skiprows=skip_rows)
    except Exception as e:
        return _dumps({"error": f"read_failed: {e}", "keywords_comp": []})

    kw_comps: Dict[str, List[float]] = {}
    analyzer = _load_vader()

    for rec, clean_text in _results_iter(
        df, selected_columns, merge_text, model_choice, template, filt, explain=False
    ):
        for tok in _token_list(clean_text):
            comp_tok = analyzer.polarity_scores(tok)["compound"]
            kw_comps.setdefault(tok, []).append(comp_tok)

    kw_list = _apply_template_overrides_to_kwlist(
        _finalize_keywords(kw_comps), template
    )
    return _dumps({"keywords_comp": kw_list})


def run_signature_detection(
    file_path: str, selected_columns: list, skip_rows: int, merge_text: bool
) -> str:
    """
    Detect recurring 'signatures' at end of text (e.g., email footers).
    Output a histogram of last N tokens and their frequency.
    """
    _ensure_pd_np()
    try:
        if file_path.lower().endswith(".xlsx"):
            df = pd.read_excel(file_path, skiprows=skip_rows)
        else:
            df = pd.read_csv(file_path, skiprows=skip_rows)
    except Exception as e:
        return _dumps({"error": f"read_failed: {e}", "signatures": []})

    sig_counts: Dict[str, int] = {}

    for i, (_, row) in enumerate(df.iterrows()):
        try:
            if merge_text and len(selected_columns) > 1:
                text = " ".join(str(row.get(c, "")) for c in selected_columns)
            else:
                col = selected_columns[0] if selected_columns else df.columns[0]
                text = str(row.get(col, ""))

            clean_text, _, _ = _strip_signature_and_handles(text)
            tail_tokens = _token_list(clean_text)[-8:]  # last 8 words
            if not tail_tokens:
                continue
            sig = " ".join(tail_tokens).lower()
            sig_counts[sig] = sig_counts.get(sig, 0) + 1
        except Exception as e:
            _dbg(f"sig_row_fail i={i}: {e}")
            print(
                json.dumps(
                    {
                        "__error__": True,
                        "where": "signatures",
                        "row_index": i,
                        "msg": str(e),
                    }
                ),
                file=sys.stderr,
                flush=True,
            )
            continue

    sig_sorted = sorted(sig_counts.items(), key=lambda kv: -kv[1])
    return _dumps({"signatures": sig_sorted[:100]})


def run_csv_preview(file_path: str, skip_rows: int) -> str:
    """
    Reads the first few rows of CSV/XLSX for preview in SwiftUI.
    Returns headers and up to PREVIEW_COUNT rows.
    """
    _ensure_pd_np()
    try:
        if file_path.lower().endswith(".xlsx"):
            df = pd.read_excel(file_path, skiprows=skip_rows)
        else:
            df = pd.read_csv(file_path, skiprows=skip_rows)
    except Exception as e:
        return _dumps({"error": f"read_failed: {e}", "headers": [], "rows": []})

    PREVIEW_COUNT = 5
    headers = list(df.columns)
    rows = df.head(PREVIEW_COUNT).to_dict(orient="records")
    return _dumps({"headers": headers, "rows": rows})


def run_synopsis_only(
    file_path: str,
    selected_columns: list,
    skip_rows: int,
    merge_text: bool,
    model_choice: str,
    template=None,
    filt=None,
    date_cfg=None,
    post_id_col_hint: Optional[str] = None,
    pdf_out: Optional[str] = None,
) -> str:
    """
    Compute only the synopsis report from the dataset.
    Always includes drivers for full detail.
    """
    _ensure_pd_np()
    try:
        if file_path.lower().endswith(".xlsx"):
            df = pd.read_excel(file_path, skiprows=skip_rows)
        else:
            df = pd.read_csv(file_path, skiprows=skip_rows)
    except Exception as e:
        return _dumps(
            {"error": f"read_failed: {e}", "synopsis": _pl_rewrite_synopsis("")}
        )

    df, grp, detected_col = _infer_bucket_series(
        df, date_cfg if date_cfg else {"group": PL_TIMELINE_GROUP}
    )

    # detect Post ID column
    detected_post_id_col = _detect_post_id_column(df, post_id_col_hint)

    out_rows: List[Dict[str, Any]] = []
    meta_final = {}
    for item in _results_iter_with_meta(
        df,
        selected_columns,
        merge_text,
        model_choice,
        template,
        filt,
        explain=True,
        grp=grp,
    ):
        if isinstance(item, tuple) and len(item) == 2 and item[0] == "__meta__":
            meta_final = item[1]["meta"]
        else:
            out_rows.append(item)

    syn = _synopsis_from_rows_and_meta(out_rows, meta_final, detected_post_id_col)
    # Optional PDF
    final_pdf = pdf_out or PL_PDF_OUT
    if final_pdf:
        ok, path_or_msg = _write_pdf_report(
            final_pdf,
            "Comprehensive Sentiment Analysis Report",
            syn.get("synopsis", ""),
            syn.get("top_drivers", {}),
            syn.get("top_posts", {}),
        )
        syn["pdf_out"] = path_or_msg if ok else None
        if not ok:
            syn["pdf_error"] = path_or_msg

    syn["detected_date_column"] = detected_col
    syn["detected_post_id_column"] = detected_post_id_col
    return _dumps(syn)


def run_detect_dates(file_path: str, skip_rows: int) -> str:
    """
    Return list of columns that appear to contain dates.
    """
    _ensure_pd_np()
    try:
        if file_path.lower().endswith(".xlsx"):
            df = pd.read_excel(file_path, skiprows=skip_rows)
        else:
            df = pd.read_csv(file_path, skiprows=skip_rows)
    except Exception as e:
        return _dumps({"error": f"read_failed: {e}", "date_columns": []})

    cols = []
    for col in df.columns:
        try:
            pd.to_datetime(
                df[col], errors="coerce", utc=True, infer_datetime_format=True
            )
            cols.append(col)
        except Exception:
            pass
    return _dumps({"date_columns": cols})


def run_model_scores(
    file_path: str,
    selected_columns: list,
    skip_rows: int,
    merge_text: bool,
    model_choice: str,
    template=None,
    filt=None,
) -> str:
    """
    Return raw model scores for all rows without final sentiment calculation.
    """
    _ensure_pd_np()
    try:
        if file_path.lower().endswith(".xlsx"):
            df = pd.read_excel(file_path, skiprows=skip_rows)
        else:
            df = pd.read_csv(file_path, skiprows=skip_rows)
    except Exception as e:
        return _dumps({"error": f"read_failed: {e}", "scores": []})

    out_rows = []
    buf: List[str] = []

    def flush_buf():
        nonlocal out_rows, buf
        if not buf:
            return
        scored = _apply_model_batch(buf, model_choice)
        for text, s in zip(buf, scored):
            out_rows.append(
                {
                    "text": text,
                    "pos": s["pos"],
                    "neu": s["neu"],
                    "neg": s["neg"],
                    "compound": s["compound"],
                    "model_label": s["model_label"],
                    "model_confidence": s["model_confidence"],
                    "used": s["used"],
                }
            )
        buf.clear()

    for _, clean in _results_iter(
        df, selected_columns, merge_text, model_choice, template, filt, explain=False
    ):
        buf.append(clean)
        if len(buf) >= BATCH:
            flush_buf()

    flush_buf()
    return _dumps({"scores": out_rows})


# Persistent JSONL "serve" loop for the Swift worker
# ───────────────────────────────────────────────────────────────


def detect_events(*args, **kwargs):
    """
    Build a robust list of timeline events.
    Accepts many call patterns and emits UI-friendly fields:
    each event includes: kind, title, label, bucket, date (ISO), timestamp (unix), value, delta?, count?, severity.
    """
    # ---- find timeline from args/kwargs/globals ----
    timeline = None
    # positional
    for a in args:
        if isinstance(a, list):
            timeline = a
            break
        if isinstance(a, dict) and "timeline" in a:
            timeline = a.get("timeline")
            break
    # keyword
    if timeline is None:
        for k in ("timeline", "result", "meta", "stats", "data"):
            obj = kwargs.get(k)
            if isinstance(obj, list):
                timeline = obj
                break
            if isinstance(obj, dict) and "timeline" in obj:
                timeline = obj.get("timeline")
                break
    # globals fallback (covers detect_events() with no args)
    if timeline is None:
        for k in (
            "LAST_TIMELINE",
            "last_timeline",
            "LAST_META",
            "last_meta",
            "META",
            "meta",
            "RESULT",
            "result",
            "STATE",
            "state",
            "CONTEXT",
            "context",
            "CACHE",
            "cache",
        ):
            obj = globals().get(k)
            if isinstance(obj, list):
                timeline = obj
                break
            if isinstance(obj, dict) and "timeline" in obj:
                timeline = obj.get("timeline")
                break

    if not timeline or not isinstance(timeline, list):
        return []

    # ---- normalize timeline entries ----
    norm = []
    for item in timeline:
        if isinstance(item, dict):
            b = item.get("bucket") or item.get("date") or item.get("bucket_start")
            v = (
                item.get("avg_compound")
                or item.get("average")
                or item.get("avg")
                or item.get("mean")
            )
            c = item.get("count") or item.get("n")
        elif isinstance(item, (list, tuple)) and len(item) >= 2:
            if isinstance(item[1], dict):
                b = item[0]
                v = (
                    item[1].get("avg_compound")
                    or item[1].get("avg")
                    or item[1].get("mean")
                )
                c = item[1].get("count") or item[1].get("n")
            else:
                b, v = item[0], item[1]
                c = item[2] if len(item) > 2 else None
        else:
            continue
        try:
            v = float(v)
        except Exception:
            continue
        try:
            c = int(c) if c is not None else None
        except Exception:
            c = None
        if not b:
            continue
        norm.append({"bucket": str(b), "avg_compound": v, "count": c})

    if not norm:
        return []

    # ---- helpers ----
    def _sev(delta):
        ad = abs(delta)
        if ad >= 0.25:
            return "high"
        if ad >= 0.15:
            return "medium"
        return "low"

    def _parse_bucket_dt(s):
        # returns (datetime_utc or None)
        try:
            if isinstance(s, (int, float)):
                return datetime.utcfromtimestamp(float(s))
            s = str(s)
            if s.endswith("Z"):
                s = s[:-1]
            try:
                return datetime.fromisoformat(s)
            except Exception:
                pass
            if len(s) == 7 and "-" in s:  # yyyy-MM
                return datetime.strptime(s + "-01", "%Y-%m-%d")
            for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f"):
                try:
                    return datetime.strptime(s, fmt)
                except Exception:
                    continue
            # epoch in seconds
            try:
                return datetime.utcfromtimestamp(float(s))
            except Exception:
                return None
        except Exception:
            return None

    def _stamp_and_iso(buck):
        dt = _parse_bucket_dt(buck)
        if dt is None:
            return None, None
        ts = int(dt.replace(tzinfo=None).timestamp())
        iso = dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        return ts, iso

    events = []

    # Best / Worst buckets
    best = max(norm, key=lambda x: x["avg_compound"])
    worst = min(norm, key=lambda x: x["avg_compound"])
    ts, iso = _stamp_and_iso(best["bucket"])
    events.append(
        {
            "kind": "best_bucket",
            "bucket": best["bucket"],
            "date": iso,
            "timestamp": ts,
            "value": round(best["avg_compound"], 3),
            "count": best["count"],
            "title": f"Best bucket: {best['bucket']}",
            "label": f"Best bucket: {best['bucket']}",
            "detail": f"avg={round(best['avg_compound'], 3)}; n={best['count']}",
            "severity": "medium",
        }
    )
    ts, iso = _stamp_and_iso(worst["bucket"])
    events.append(
        {
            "kind": "worst_bucket",
            "bucket": worst["bucket"],
            "date": iso,
            "timestamp": ts,
            "value": round(worst["avg_compound"], 3),
            "count": worst["count"],
            "title": f"Worst bucket: {worst['bucket']}",
            "label": f"Worst bucket: {worst['bucket']}",
            "detail": f"avg={round(worst['avg_compound'], 3)}; n={worst['count']}",
            "severity": "medium",
        }
    )

    # Spikes / drops vs previous bucket (skip tiny buckets)
    min_count = kwargs.get("min_count", 30)
    threshold = kwargs.get("threshold", 0.2)
    prev = None
    for cur in norm:
        if prev is None:
            prev = cur
            continue
        if cur["count"] is not None and prev["count"] is not None:
            if cur["count"] < min_count or prev["count"] < min_count:
                prev = cur
                continue
        delta = cur["avg_compound"] - prev["avg_compound"]
        if abs(delta) >= threshold:
            kind = "spike_up" if delta > 0 else "spike_down"
            ts, iso = _stamp_and_iso(cur["bucket"])
            events.append(
                {
                    "kind": kind,
                    "bucket": cur["bucket"],
                    "date": iso,
                    "timestamp": ts,
                    "value": round(cur["avg_compound"], 3),
                    "delta": round(delta, 3),
                    "count": cur["count"],
                    "title": ("Spike" if delta > 0 else "Drop")
                    + f" on {cur['bucket']}",
                    "label": ("Spike" if delta > 0 else "Drop")
                    + f" on {cur['bucket']}",
                    "detail": f"change={round(delta, 3)}; avg={round(cur['avg_compound'], 3)}; n={cur['count']}",
                    "severity": _sev(delta),
                }
            )
        prev = cur

    # Recent slope over last k buckets
    k = max(3, int(kwargs.get("slope_window", 3)))
    if len(norm) >= k:
        tail = norm[-k:]
        xs = list(range(k))
        ys = [t["avg_compound"] for t in tail]
        n = float(k)
        sx = sum(xs)
        sy = sum(ys)
        sxx = sum(x * x for x in xs)
        sxy = sum(x * y for x, y in zip(xs, ys))
        den = (n * sxx - sx * sx) or 1.0
        slope = (n * sxy - sx * sy) / den
        last_ts, last_iso = _stamp_and_iso(tail[-1]["bucket"])
        events.append(
            {
                "kind": "recent_slope",
                "window": k,
                "slope": round(slope, 4),
                "bucket": tail[-1]["bucket"],
                "date": last_iso,
                "timestamp": last_ts,
                "title": f"Recent trend ({k} buckets)",
                "label": f"Recent trend ({k} buckets)",
                "detail": f"slope per bucket={round(slope, 4)}",
                "severity": _sev(slope),
            }
        )

    # deterministic ordering for UI
    def _order_key(e):
        rank = {
            "worst_bucket": 0,
            "best_bucket": 1,
            "spike_down": 2,
            "spike_up": 3,
            "recent_slope": 4,
        }
        return (
            rank.get(e.get("kind"), 99),
            str(e.get("bucket", "")),
            e.get("title", ""),
        )

    events.sort(key=_order_key)
    return events


def _serve_loop():
    """
    Minimal, single-final-line serve loop.
    Emits exactly one 'final' wrapper for analyze, and no legacy duplicates.
    Accepts alias keys: 'filter'/'filt', 'merge'/'merge_text', 'date'/'datecfg'/'date_filter'.
    """
    # Handshake
    print('{"ready":true}', flush=True)

    import time as _time

    while True:
        line = sys.stdin.readline()
        if line == "":
            _time.sleep(0.05)
            continue
        line = line.strip()
        if not line:
            continue

        try:
            req = json.loads(line)
        except Exception as e:
            print(json.dumps({"error": f"bad_json:{e}"}), flush=True)
            continue

        # Environment passthrough (refresh runtime toggles)
        env = req.get("env")
        if isinstance(env, dict):
            try:
                os.environ.update(
                    {k: ("" if v is None else str(v)) for k, v in env.items()}
                )
            except Exception:
                for k, v in env.items():
                    os.environ[k] = "" if v is None else str(v)
            globals()["PL_SIGNATURES_ENABLED"] = (
                os.environ.get("PL_SIGNATURES_ENABLED", "1") != "0"
            )
            globals()["PL_USERNAME_REMOVAL"] = (
                os.environ.get("PL_USERNAME_REMOVAL", "1") != "0"
            )
            globals()["PL_OUT"] = os.environ.get("PL_OUT", "")
            globals()["PL_PDF_OUT"] = os.environ.get("PL_PDF_OUT", "")
            globals()["PL_TIMELINE_GROUP"] = os.environ.get(
                "PL_TIMELINE_GROUP", "D"
            ).upper()
            try:
                globals()["PL_PROGRESS_EVERY"] = int(
                    os.environ.get("PL_PROGRESS_EVERY", "2000")
                )
            except Exception:
                globals()["PL_PROGRESS_EVERY"] = 2000

        op = req.get("op")
        try:
            if op == "warmup":
                m = req.get("model", "vader")
                if m in ("social", "community"):
                    _load_transformers()
                    _apply_model_batch(["warmup"], m)
                elif m == "vader":
                    _load_vader()
                    _load_spacy()
                    _apply_model_batch(["warmup"], "vader")
                print(json.dumps({"ok": True, "op": "warmup", "model": m}), flush=True)

            elif op == "score":
                out = json.loads(
                    score_sentence(
                        req.get("text", ""),
                        req.get("model", "vader"),
                        template=req.get("template"),
                        explain=True,
                    )
                )
                print(json.dumps(out), flush=True)

            elif op == "analyze":
                merge_val = req.get("merge_text", req.get("merge", False))
                date_cfg_val = (
                    req.get("date_filter") or req.get("datecfg") or req.get("date")
                )
                filt_val = req.get("filter", req.get("filt"))

                res = json.loads(
                    run_sentiment_analysis(
                        req["file"],
                        req["columns"],
                        req.get("skip_rows", 0),
                        merge_val,
                        req.get("model", "vader"),
                        template=req.get("template"),
                        filt=filt_val,
                        explain=True,
                        date_cfg=date_cfg_val,
                        synopsis=True,
                        post_id_col_hint=req.get("post_id"),
                        pdf_out=req.get("pdf_out"),
                        events=req.get("events"),
                    )
                )
                # Emit exactly one final wrapper for Swift
                print(json.dumps({"status": "final", "result": res}), flush=True)

            else:
                print(json.dumps({"error": "unknown op"}), flush=True)

        except Exception as e:
            print(json.dumps({"error": str(e)}), flush=True)


if __name__ == "__main__":
    if _IN_SERVE_MODE:
        _serve_loop()


# === Clean synopsis formatting helpers (AUTO-INJECTED) ===
def _pl_clean_synopsis_text(txt: str) -> str:
    if not txt:
        return txt
    out = []
    for line in str(txt).splitlines():
        st = line.strip()
        if re.fullmatch(r"[═─—━]+", st):  # drop heavy rules
            continue
        if st.lower().startswith("generated by "):  # drop boilerplate
            continue
        out.append(line)
    cleaned = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip() + "\n"
    return cleaned


def _pl_two_col_keywords_from_comp(
    keywords_comp, left_title="Top Positive", right_title="Top Negative", k=10
) -> str:
    try:
        pos = [
            d.get("word", "")
            for d in sorted(
                [d for d in keywords_comp if d.get("compound", 0) > 0],
                key=lambda x: x.get("compound", 0),
                reverse=True,
            )[:k]
        ]
        neg = [
            d.get("word", "")
            for d in sorted(
                [d for d in keywords_comp if d.get("compound", 0) < 0],
                key=lambda x: x.get("compound", 0),
            )[:k]
        ]
    except Exception:
        return ""
    width = 28
    lines = []
    lines.append(f"{left_title:<{width}}{right_title}")
    lines.append(f"{'-'*len(left_title):<{width}}{'-'*len(right_title)}")
    m = max(len(pos), len(neg))
    for i in range(m):
        l = f"• {pos[i]}" if i < len(pos) else ""
        r = f"• {neg[i]}" if i < len(neg) else ""
        lines.append(f"{l:<{width}}{r}")
    return "\n".join(lines) + "\n"


def _pl_rewrite_synopsis(original: str, meta: dict) -> str:
    txt = _pl_clean_synopsis_text(original or "")
    kw = meta.get("keywords_comp") or []
    table = _pl_two_col_keywords_from_comp(kw)
    if table:
        # remove any existing "Top Positive/Negative Keywords" bullet blocks
        pat = re.compile(r"(?si)Top Positive Keywords.*?(Top Negative Keywords.*?\n)?")
        txt2, n = pat.sub("", txt)
        if n == 0:
            return txt.rstrip() + "\n\nKeywords\n" + table
        return txt2.rstrip() + "\n\nKeywords\n" + table
    return txt


# === end helpers ===
