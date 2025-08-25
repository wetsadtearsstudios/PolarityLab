import sys, json, os
sys.path.insert(0, os.environ.get("RES", os.path.dirname(__file__)))

import polarity_sentiment as pl

def main():
    try:
        req = json.load(sys.stdin)
        res = pl.run_model_scores(
            file_path=req["file_path"],
            selected_columns=req.get("selected_columns", []),
            skip_rows=int(req.get("skip_rows", 0)),
            merge_text=bool(req.get("merge_text", True)),
            model_choice=req.get("model_choice", "vader"),
        )
        data = json.loads(res) if isinstance(res, (str, bytes)) else res
        json.dump(data, sys.stdout)
    except Exception as e:
        json.dump({"error": str(e)}, sys.stdout)
        return 1

if __name__ == "__main__":
    sys.exit(main())