"""逐題難度判斷：產生 tools/data/difficulty.json（題目編號 → 1／2／3）。

難度定義（依三階段考核規格）：
  1 基礎：現行規則、流程、來源辨識（滿 1 個月考核）
  2 情境應用：資料不足、條件改變、追問、情緒、補問與求助（滿 3 個月考核）
  3 綜合：跨主題案件、客訴、補償、權限判斷、跨部門交接（滿 6 個月考核）

做法：
  總表規則題（來源 rules）：逐題判斷。現行規定、紅線、傳言與新舊衝突（來源辨識）＝1；
    經驗談應對題依客人類型判斷（見 TIP）。
  案例題（rules_ext、legacy）：由人逐一閱讀 100 個情境，判斷情境複雜度 CASE_LEVEL（1 單一規則且明確、
    2 資料不足／條件改變／情緒、3 客訴／補償／高風險／資安個資／權限／跨部門交接），再依「問法」查表。
"""
import json
import re
import sys
from pathlib import Path

# 情境複雜度：預設 2；下列為人工閱讀後判定為 1 或 3 的案例編號
CASE_1 = {8, 16, 23, 31, 33, 34, 39, 41, 42, 43, 44, 46, 47, 49, 50, 51, 52, 57, 67, 69, 70, 71, 73, 74, 89,
          12, 21, 22, 25, 26, 32}
CASE_3 = {2, 10, 20, 30, 54, 55, 66, 68, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 90, 91, 92, 94, 95, 96, 97, 99, 29}

# 經驗談（TIP）應對題：情緒、補問、安撫＝2；牽涉補償、媒體客訴、大量進線＝3
TIP = {"X01": 2, "X02": 2, "X03": 3, "X04": 2, "X05": 2, "X06": 3, "X07": 2, "X08": 3, "X09": 2, "X10": 2, "X11": 2}

# 問法分類（取題幹最後一行）
ASK_PATTERNS = [
    ("G", r"第二輪回覆"),
    ("F", r"以下哪一個回覆最適合"),
    ("E", r"交給主管|要升級|不該自己處理|停止自己處理"),
    ("A", r"先查哪些資料|先核對|先查證|第一輪要確認"),
    ("B", r"限制|界線|不能直接照顧客|不能直接當成事實"),
    ("C", r"查證完後|下一步|系統或流程|如何推進"),
    ("D", r"怎麼回覆|客服的口吻|現在能對顧客說|先回一句話|回報|向主管|回應現場同事|說明目前的狀況"),
]
# 問法 × 情境複雜度 → 難度
MATRIX = {"A": (1, 1, 2), "B": (1, 1, 2), "C": (1, 1, 2),
          "F": (1, 2, 3), "D": (2, 2, 3), "E": (2, 2, 3), "G": (2, 2, 3)}


def ask_of(stem: str):
    last = [ln for ln in stem.split("\n") if ln.strip()][-1]
    for k, pat in ASK_PATTERNS:
        if re.search(pat, last):
            return k
    return None


def case_no(qid: str) -> int:
    """題目編號 → 案例編號（1–100）。L 題每個案例 5 題（L001–L005 屬案例 1）；M、D 題的編號就是案例編號。"""
    m = re.fullmatch(r"L-([LMD])(\d+)", qid)
    kind, num = m.group(1), int(m.group(2))
    return (num - 1) // 5 + 1 if kind == "L" else num


def judge(q) -> int:
    if q["source"] == "rules":
        if q["id"].startswith("TIP-"):
            return TIP[q["id"].split("-")[1]]
        return 1
    n = case_no(q["id"])
    level = 3 if n in CASE_3 else 1 if n in CASE_1 else 2
    k = ask_of(q["stem"])
    if k is None:
        raise ValueError(f"無法判斷問法：{q['id']}")
    return MATRIX[k][level - 1]


ASK_NAMES = {"A": "查證／核對資料", "B": "規則限制與界線", "C": "查證後的下一步／流程", "D": "撰寫回覆或回報",
             "E": "何時升級、求助", "F": "選出最適合的回覆（選擇題）", "G": "追問／情緒的第二輪回覆"}
CASE_NAMES = {1: "單一規則、情境明確", 2: "資料不足／條件改變／情緒", 3: "客訴／補償／高風險／個資／權限／跨部門"}


def explain(q) -> dict:
    """給交接包用：這題為什麼是這個難度。"""
    if q["source"] == "rules":
        if q["id"].startswith("TIP-"):
            return {"依據": "經驗談應對題：依客人類型分級（情緒、補問＝Lv.2；補償、媒體客訴、大量進線＝Lv.3）", "情境複雜度": "", "問法": ""}
        return {"依據": "總表規則題（現行規定、紅線、傳言、新舊衝突、來源辨識）＝基礎", "情境複雜度": "", "問法": ""}
    n = case_no(q["id"])
    level = 3 if n in CASE_3 else 1 if n in CASE_1 else 2
    return {"依據": f"案例 {n}：情境複雜度 × 問法", "情境複雜度": f"{level} {CASE_NAMES[level]}", "問法": ASK_NAMES[ask_of(q["stem"])]}


def main(questions_json, out_json):
    qs = json.loads(Path(questions_json).read_text(encoding="utf-8"))
    out = {q["id"]: judge(q) for q in qs}
    Path(out_json).write_text(json.dumps(out, ensure_ascii=False, indent=0, sort_keys=True), encoding="utf-8", newline="\n")
    return out


if __name__ == "__main__":
    import collections
    qs = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    r = main(sys.argv[1], sys.argv[2])
    print(collections.Counter(r.values()))
    print(collections.Counter((q["qtype"] == "short", r[q["id"]]) for q in qs))
