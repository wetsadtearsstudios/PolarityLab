import os
import sys
from pathlib import Path

# Force offline mode
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_OFFLINE"]   = "1"

# Paths to resources
BASE_DIR            = Path(__file__).resolve().parent
VADER_LEXICON       = BASE_DIR / "vader_lexicon.txt"
EMOJI_LEXICON       = BASE_DIR / "emoji_utf8_lexicon.txt"
SOCIAL_MODEL_DIR    = BASE_DIR / "twitter-roberta-base-sentiment"
COMMUNITY_MODEL_DIR = BASE_DIR / "bertweet-base-sentiment-analysis"
SPACY_MODEL_DIR     = BASE_DIR / "en_core_web_sm"

# Now import and debug-print versions
import transformers
import huggingface_hub
print("transformers version:", transformers.__version__, file=sys.stderr)
print("huggingface_hub version:", huggingface_hub.__version__, file=sys.stderr)
print("SOCIAL_MODEL_DIR exists?", SOCIAL_MODEL_DIR.exists(), file=sys.stderr)
print("COMMUNITY_MODEL_DIR exists?", COMMUNITY_MODEL_DIR.exists(), file=sys.stderr)

# Core imports
import pandas as pd
import json
import re
from nltk.sentiment.vader import SentimentIntensityAnalyzer
from transformers import AutoModelForSequenceClassification, AutoTokenizer, pipeline
import spacy

# Ensure spaCy path
sys.path.insert(0, str(SPACY_MODEL_DIR))

# Initialize VADER
analyzer = SentimentIntensityAnalyzer(lexicon_file=str(VADER_LEXICON))
base_lex = analyzer.lexicon.copy()

def _load_emoji_scores(path: Path, base_lexicon: dict):
    scores = {}
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return scores
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        emo, desc = parts
        words = re.findall(r"\b\w+\b", desc.lower())
        s = sum(base_lexicon.get(w, 0.0) for w in words)
        if s:
            scores[emo] = s
    return scores

emoji_scores = _load_emoji_scores(EMOJI_LEXICON, base_lex)
for emo, val in emoji_scores.items():
    analyzer.lexicon[f" {emo} "] = val

# ── Load Social‐media model (fully local) ─────────────────────────
social_model = AutoModelForSequenceClassification.from_pretrained(
    SOCIAL_MODEL_DIR,
    local_files_only=True
)
# **Inject proper label mapping**
social_model.config.id2label = {
    0: "NEGATIVE",
    1: "NEUTRAL",
    2: "POSITIVE"
}

social_tokenizer = AutoTokenizer.from_pretrained(
    SOCIAL_MODEL_DIR,
    local_files_only=True
)
social_pipeline = pipeline(
    "sentiment-analysis",
    model=social_model,
    tokenizer=social_tokenizer
)

# ── Load Community‐trained model (fully local) ─────────────────────
community_model = AutoModelForSequenceClassification.from_pretrained(
    COMMUNITY_MODEL_DIR,
    local_files_only=True
)
# **Inject proper label mapping** (adjust indices to match your community model)
community_model.config.id2label = {
    0: "NEGATIVE",
    1: "NEUTRAL",
    2: "POSITIVE"
}

community_tokenizer = AutoTokenizer.from_pretrained(
    COMMUNITY_MODEL_DIR,
    local_files_only=True
)
community_pipeline = pipeline(
    "sentiment-analysis",
    model=community_model,
    tokenizer=community_tokenizer
)

# Load spaCy
print(f"📦 Loading spaCy model from: {SPACY_MODEL_DIR}", file=sys.stderr)
nlp = spacy.load(SPACY_MODEL_DIR)

def spacy_negation_detected(text: str) -> bool:
    doc = nlp(text)
    return any(
        token.dep_ == "neg" and token.head.pos_ in {"ADJ", "VERB"}
        for token in doc
    )

def run_sentiment_analysis(
    file_path: str,
    selected_columns: list[str],
    skip_rows: int,
    merge_text: bool,
    model_choice: str  # "vader", "social", or "community"
) -> str:
    # ─── DEBUG: log incoming arguments ─────
    print(f"🔍 DEBUG Python run_sentiment_analysis called with:", file=sys.stderr)
    print(f"    file_path       = {file_path!r}", file=sys.stderr)
    print(f"    selected_columns= {selected_columns!r}", file=sys.stderr)
    print(f"    skip_rows       = {skip_rows}", file=sys.stderr)
    print(f"    merge_text      = {merge_text}", file=sys.stderr)
    print(f"    model_choice    = {model_choice!r}", file=sys.stderr)
    # ────────────────────────────────────────

    df = (
        pd.read_excel if file_path.lower().endswith(".xlsx")
        else pd.read_csv
    )(file_path, skiprows=skip_rows)

    out_rows = []
    kw_comps = {}
    orig_cols = list(df.columns)

    score_cols = ["pos", "neu", "neg", "compound"]
    model_cols = ["model_label", "model_confidence"]
    extra_cols = ["spacy_negation", "final_sentiment"]

    # ─── DEBUG: branch selection ────────────
    if model_choice == "social":
        print("🔍 DEBUG Python selecting SOCIAL pipeline", file=sys.stderr)
        pipeline_fn = social_pipeline
    elif model_choice == "community":
        print("🔍 DEBUG Python selecting COMMUNITY pipeline", file=sys.stderr)
        pipeline_fn = community_pipeline
    else:
        print("🔍 DEBUG Python defaulting to VADER-only", file=sys.stderr)
        pipeline_fn = None
    # ────────────────────────────────────────

    for _, row in df.iterrows():
        # build text
        text = (
            " ".join(str(row[c]) for c in selected_columns if c in row)
            if merge_text else str(row.get(selected_columns[0], ""))
        )
        # pad emojis
        for emo in emoji_scores:
            text = text.replace(emo, f" {emo} ")
        vader_scores = analyzer.polarity_scores(text)

        if pipeline_fn is not None:
            raw = pipeline_fn(text, return_all_scores=True)[0]
            # map native scores: raw is a list of dicts with label/score
            scores_map = {d['label']: d['score'] for d in raw}
            # assign
            neg = scores_map.get('NEGATIVE', 0.0)
            neu = scores_map.get('NEUTRAL',  0.0)
            pos = scores_map.get('POSITIVE', 0.0)
            # proxy compound
            compound = pos - neg
            model_label = max(scores_map, key=scores_map.get)
            model_confidence = round(scores_map[model_label], 3)
        else:
            neg = vader_scores['neg']
            neu = vader_scores['neu']
            pos = vader_scores['pos']
            compound = vader_scores['compound']
            comp = compound
            if comp >= 0.05:
                base_label = "POSITIVE"
            elif comp <= -0.05:
                base_label = "NEGATIVE"
            else:
                base_label = "NEUTRAL"
            model_label = base_label
            model_confidence = 1.0

        is_negated = spacy_negation_detected(text)
        final_sent = (
            {"POSITIVE": "NEGATIVE","NEGATIVE": "POSITIVE"}.get(model_label, model_label)
            if is_negated else model_label
        )

        rec = {c: row[c] for c in orig_cols}
        rec.update({"pos": pos, "neu": neu, "neg": neg, "compound": compound})
        rec.update({
            "model_label":      model_label,
            "model_confidence": model_confidence,
            "spacy_negation":   is_negated,
            "final_sentiment":  final_sent
        })
        out_rows.append(rec)

        for tok in re.findall(r"\b\w+\b", text.lower()):
            comp_tok = analyzer.polarity_scores(tok)["compound"]
            kw_comps.setdefault(tok, []).append(comp_tok)

    kw_comp_list = [
        {"word": w, "compound": round(sum(vals)/len(vals), 2)}
        for w, vals in sorted(kw_comps.items(),
                              key=lambda kv: -abs(sum(kv[1])/len(kv[1])))
    ]

    headers = orig_cols + score_cols + model_cols + extra_cols
    return json.dumps({
        "rows":          out_rows,
        "row_headers":   headers,
        "keywords_comp": kw_comp_list
    })
