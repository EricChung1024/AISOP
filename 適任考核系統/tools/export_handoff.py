"""產生「評分系統資料包」：題庫（含標準答案與得分點）、總表原始資料、題目→規則對照、資料庫快照、資料表結構與說明文件。
內容含標準答案，只放本機，不要提交、不要放上公開網站。"""
import collections
import csv
import json
import shutil
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_questions as bq  # noqa: E402
import export_questions as eq  # noqa: E402
from xlsx_reader import read_rows, sheet_names  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TOP = "評分系統資料包"
SITE_URL = "https://ericchung1024.github.io/AISOP-exam/"
SUPABASE_REF = "pdfdyuahpshrrdwkvyyh"


def _write_csv(path: Path, rows, header=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        if header:
            w.writerow(header)
        w.writerows(rows)


def _case_rows(case_map, rules):
    rule_name = {r[0]: r[2] for r in rules}
    with (ROOT / "AI專屬客服測驗" / "題庫案例來源.tsv").open(encoding="utf-8-sig", newline="") as f:
        src = list(csv.DictReader(f, delimiter="|"))
    rows = []
    for i, c in enumerate(src, 1):
        cid = f"C{i:03d}"
        e = case_map.get(cid)
        if e:
            ids = e["rules"]
            rows.append([cid, c["主題"], c["情境"], "總表延伸", "、".join(ids), "、".join(rule_name.get(x, "") for x in ids), 7,
                         "依總表規則改寫答案、得分點與選擇題的正確回覆"])
        else:
            rows.append([cid, c["主題"], c["情境"], "維持原通用內容（總表無對應規則）", "", "", 7,
                         "總表沒有對應的規則，未編造制度；內容為通用電商客服原則，題目標示未審核"])
    return rows


def _stats(questions):
    by_src = collections.Counter((q["source"], q["qtype"]) for q in questions)
    return {
        "total": len(questions),
        "reviewed": sum(1 for q in questions if q["reviewed"]),
        "rules": sum(1 for q in questions if q["source"] == "rules"),
        "ext": sum(1 for q in questions if q["source"] == "rules_ext"),
        "legacy": sum(1 for q in questions if q["source"] == "legacy"),
        "short": sum(1 for q in questions if q["qtype"] == "short"),
        "choice": sum(1 for q in questions if q["qtype"] != "short"),
        "red": sum(1 for q in questions if q["red_line"]),
        "by_src": by_src,
        "by_stage": collections.Counter(q["stage"] for q in questions),
        "by_diff": collections.Counter(q.get("difficulty") for q in questions),
    }


def readme_text(s, db):
    stages = "、".join(f"第{k}章 {v}" for k, v in sorted(s["by_stage"].items()))
    attempts = len(db.get("attempts", []))
    answers = len(db.get("attempt_answers", []))
    diff = "、".join(f"Lv.{k}：{v} 題" for k, v in sorted(s["by_diff"].items()))
    return f"""# 評分系統資料包（交接用）

> **內容含標準答案、得分點與考生作答，只在內部流通，不要放上公開網站或公開 repo。**

這包資料是「適任考核系統」目前的全部內容，給接手做**評分標準與評分系統**的人使用。資料全為虛構（好物集客服 SOP）。

## 一、先看這裡：系統現況

| 項目 | 內容 |
|---|---|
| 網站 | {SITE_URL}（靜態前端，GitHub Pages；repo：`EricChung1024/AISOP-exam`） |
| 原始碼與文件 | repo `EricChung1024/AISOP`，資料夾 `適任考核系統/`（含設計文件、實作計畫、測試） |
| 後端 | Supabase 專案 `{SUPABASE_REF}`（登入、資料庫、權限規則、評分函式） |
| 新增員工 | Supabase Edge Function `create-employees`（主管專用） |
| 資料庫快照時間 | {db.get('exported_at', '—')}（{attempts} 份考卷、{answers} 筆作答） |

**已完成**：三階段考核（滿 1／3／6 個月）、題庫依難度（Lv.1／2／3）隨機抽題成草稿考卷、主管審核與鎖定後才出題、選擇題自動評分、簡答自評＋主管覆核、紅線題不得抵銷、題庫審核與刪除。
**尚未完成（交給你）**：評分標準本身（見第七節）、簡答題的評分方式、AI 自動出題（後端函式未實作）。

## 二、資料包內容

| 路徑 | 說明 |
|---|---|
| `data/題庫_全部.csv` | 全部 {s['total']} 題，Excel 可直接開（UTF-8 含 BOM）。含難度、正確答案、解析、得分點、錯誤類型、來源、審核狀態。CSV 的「階段」欄是**主題（第 1–9 章）**，不是考核階段 |
| `data/題庫_全部.json` | 同上，完整欄位的機器可讀版（與資料庫 `questions` 表一致，含 `difficulty`） |
| `data/難度判斷對照.csv` | 每一題的難度與判斷依據（情境複雜度、問法）。**評分標準請從這份檢查起** |
| `data/總表/*.csv` | 「統整結果_標準答案總表」8 個工作表的原始內容（規則總表、經驗談、傳言、新人問答等）。**這是所有標準答案的最終依據** |
| `data/案例對照_題目到總表規則.csv` | 舊題庫 100 個案例各自對應到哪條總表規則，或為何沒有對應 |
| `data/db_snapshot.json` | 資料庫目前的資料（考卷、作答、錯題）。使用者信箱不在其中。**快照為空時代表匯出當下沒有連上資料庫，不代表沒有資料** |
| `schema/setup.sql` | 完整資料表、權限規則與函式（001–008 合併，可在乾淨的 Supabase 專案重建） |

## 三、三階段考核與題庫分級

**章節測驗已移除**。舊階段（0–11）與歷史考卷保留唯讀（`assessments.active = false`），不能再開考。

| 等級（依年資自動變更） | 考核 | 階段編號 | 題數 | 通過分 | 抽題難度 |
|---|---|---|---|---|---|
| Lv.1 客服實習生（到職～滿 1 個月前） | 基礎考核 | 12 | 20（全選擇） | 80 | Lv.1 |
| Lv.2 客服助理（滿 1～3 個月前） | 情境應用考核 | 13 | 20（簡答 ≤2） | 85 | Lv.2 |
| Lv.3 客服專員（滿 3～6 個月） | 綜合考核 | 14 | 20（簡答 ≤3） | 90 | Lv.3 |

- 考核日期以到職日為準：滿 1、3、6 個月同日；當月沒有同日採月底；遇週六日順延到下一個工作日（`exam_due_date`）。國定假日沒有資料。
- 等級在年資到期時變更，不受考核通過與否影響；未通過標示「階段認證待補強」，不降等。升等不增加退款、補償或其他操作權限。
- 綜合考核另需**實務驗證、案例分享、主管確認**，這三項在系統外進行，系統只記錄筆試分數。
- 紅線題答錯＝不通過，不能用其他題的高分抵銷（`red_line_failed`）。
- 分數門檻是培訓設計，**正式上線前需用案例試評校準**。

**出題流程**（`create_paper` → `remove_from_paper` → `refill_paper` → `lock_paper` → 員工 `start_exam`）：
1. 主管為某員工、某階段產生**草稿考卷**：依該階段難度隨機抽 20 題，題目盡量平均分到九個主題。
2. 主管檢查每題難易度是否合適，不合適的**刪除**（暫時抽出放一邊，不歸檔）。
3. 按「隨機補到 20 題」補滿；被刪的題不會補回同一份考卷。
4. 「鎖定並出題」後題目不能再改（鎖定時那 20 題標為已審核），員工才看得到（`my_papers`）並能開始考；員工沒有鎖定的考卷時 `start_exam` 回 `NO_PAPER`。

**牌堆規則**：題庫像一副牌（以「難度＋題型」各一副）。抽進考卷的題目標記 `used`，這一輪不再被抽到；刪除標記 `removed`；某副牌抽完、補不滿時，該副牌全部重洗（`used`、`removed` 清除），開始新一輪；重洗後仍不足才由相鄰難度補。

## 四、題庫組成（請先了解品質差異）

共 **{s['total']}** 題：選擇／是非 {s['choice']} 題、情境簡答 {s['short']} 題；紅線題 {s['red']} 題。**只有 {s['reviewed']} 題已審核**。難度分布：{diff}。

| 來源（`source`） | 題數 | 說明 | 審核 |
|---|---|---|---|
| `rules` 總表規則題 | {s['rules']} | 由總表的現行規則、紅線、新舊衝突、傳言、經驗談直接產生。答案與干擾選項（舊版寫法）都來自總表 | 已審核 |
| `rules_ext` 總表延伸 | {s['ext']} | 舊題庫的情境，**答案與得分點改依總表規則改寫**（64 個案例 × 7 題）。改寫內容由 AI 撰寫、依總表規則為準 | **未審核**，建議人工抽查 |
| `legacy` 舊題庫 | {s['legacy']} | 36 個案例在總表找不到對應規則，維持原本的**通用**內容（沒有具體數字或期限） | **未審核**，不建議直接拿來評分 |

各章（主題）題數：{stages}。

**難度是怎麼判斷的**（`tools/judge_difficulty.py`、`data/難度判斷對照.csv`）：
- 總表規則題（85 題）逐題判斷：現行規定、紅線、傳言與新舊衝突（來源辨識）＝Lv.1；經驗談應對題依客人類型分級（情緒、補問＝Lv.2；補償、媒體客訴、大量進線＝Lv.3）。
- 案例題（700 題）：先由人讀完 100 個情境，判斷**情境複雜度**（1 單一規則且明確；2 資料不足／條件改變／情緒；3 客訴／補償／高風險／個資／權限／跨部門），再依**問法**（查證、界線、下一步、撰寫回覆、升級求助、追問）查表得出難度。
- 這是依三階段規格的定義做的**暫定分級，沒有經過作答資料校準，也沒有人複核**，特別是被歸為 Lv.3 的 27 個案例。

提醒：
- `legacy` 選擇題的解析寫「A 錯誤／B 正確」，所以 `shuffle = false`（選項順序固定）；其餘題目每次抽題都會打亂選項。
- 簡答題的 `rubric`（得分點）是字串陣列：`rules_ext` 由答案以「；」切成要點；`legacy` 只有一個要點。多輪追問題（`L-D###`）的得分點是兩條：回覆重點、判斷邊界。

## 五、目前的評分邏輯（`supabase/setup.sql` 的 003、004、005）

**選擇題／是非題（自動評分）**
- 交卷（`submit_exam`）時，伺服器把員工選的選項還原成「原始選項 index」，與 `questions.correct_index` 比對。沒作答＝答錯。
- 選項順序隨機，打亂後的順序存在 `attempts.question_ids[].perm`（`perm[畫面位置] = 原始 index`）。`attempt_answers.choice` 存的是**原始 index**，不是畫面位置。

**情境簡答題（自評＋主管覆核）**
- 交卷後狀態變 `pending_selfcheck`，才揭曉參考答案與得分點；員工逐項勾選「我有做到」（`submit_selfcheck`）。
- 題分 ＝ 勾選數 ÷ 得分點數（0–1）；**空白作答一律 0 分**（不能靠勾選拿分）。
- 主管可在員工詳情頁覆核並調整單題分數（`adjust_short_score`，0–1），整份考卷會重算。

**總分與通過**
- `總分 = 100 × (0.8 × 選擇題答對率 + 0.2 × 簡答平均得分)`；只有一種題型時，該題型佔 100%。四捨五入到小數一位。
- 通過條件：總分 ≥ `assessments.pass_score`（80／85／90）**且沒有答錯任何紅線題**（紅線簡答題要拿滿分）。

**錯誤類型（`error_type`）與細節（`error_detail`）**
- `用了舊規則`（細節＝選到的是哪一版舊文件，例：2022 手冊）、`違反紅線`、`被舊資訊誤導`、`把傳言當規定`、`應對方式不當`、`情境判斷失誤`。
- 簡答題未得滿分時：`error_type` 取題目的錯誤類型，`error_detail` 取題目的 `key_error`（關鍵失誤）。

**錯題區（`wrong_book`）**
- 答錯（或簡答未得滿分）自動收進；重練（`start_practice`／`submit_practice`，只含選擇題）連續答對 2 次 → `mastered`；重練**不計入**成績；已刪除的題目不會出現在重練。

## 六、資料表與後端函式

| 表 | 重點欄位 |
|---|---|
| `profiles` | `id`（＝auth 使用者 id）、`name`、`role`（`employee`／`supervisor`）、`hire_date` |
| `assessments` | `stage` 0–14、`name`、`kind`、`total_questions`、`short_max`、`pass_score`、`active`（舊階段 false）、`difficulty`、`due_months` |
| `questions` | `id`、`stage`（**主題 1–9**）、`difficulty`（1–3）、`qtype`(`mcq`/`tf`/`short`)、`stem`、`options`、`correct_index`、`explanation`、`error_type`、`error_detail`、`option_errors`、`reference_answer`、`rubric`、`key_error`、`source`、`source_ref`、`reviewed`、`red_line`、`shuffle`、`removed`／`removed_at`／`removed_by`（暫時刪除）、`used`（這一輪已抽過） |
| `attempts` | `id`、`user_id`、`stage`（考核階段 12–14；舊紀錄 0–11）、`question_ids`（題目順序與 `perm`）、`status`、`score`、`passed`、`started_at`、`submitted_at` |
| `attempt_answers` | 主鍵 (`attempt_id`,`question_id`)；`choice`、`text_answer`、`checked`、`points`、`is_correct`、`error_type`、`error_detail` |
| `exam_papers` | 考卷：`user_id`、`stage`、`question_ids`、`rejected_ids`（被刪掉的題）、`status`（`draft`／`locked`／`used`）、`created_by`、`locked_at`、`attempt_id`。對用戶端完全不開放 |
| `wrong_book`、`practice_runs` | 錯題區與重練抽題紀錄 |

檢視：`v_exam_schedule`（每位員工三次考核日期、目前等級、各階段通過狀態）、`v_stage_summary`、`v_error_counts`、`v_assessments`。

| 函式 | 誰能用 | 用途 |
|---|---|---|
| `my_papers()` | 登入者 | 看自己有哪些已鎖定、可開始考的考卷（不含題目編號） |
| `start_exam(p_stage)` | 登入者 | 用已鎖定的考卷建立作答（**不含答案**）；階段需為 12–14；沒有鎖定考卷回 `NO_PAPER` |
| `submit_exam`、`submit_selfcheck` | 登入者 | 評選擇題；簡答自評後結算分數與是否通過 |
| `list_wrong`、`start_practice`、`submit_practice`、`set_wrong_note`、`set_wrong_status` | 登入者 | 錯題區 |
| `adjust_short_score`、`set_reviewed`、`set_hire_date`、`get_employee_detail` | 主管 | 覆核與管理 |
| `list_questions_for_review`、`list_attempt_questions`、`remove_questions`、`restore_questions` | 主管 | 題庫審核；刪除＝暫時移出牌堆（資料保留，暫不歸檔） |

錯誤代碼：`NOT_AUTHENTICATED`、`BAD_STAGE`（階段不存在或已停用）、`NO_QUESTIONS`、`NO_PAPER`、`PAPER_EXISTS`、`PAPER_NOT_FULL`、`PAPER_LOCKED`、`ATTEMPT_CLOSED`、`NO_WRONG`、`BAD_STATUS`、`BAD_POINTS`、`FORBIDDEN`、`NOT_FOUND`。

權限：所有資料表只開放登入者**讀取**自己的資料（主管讀全部）；`questions`、`practice_runs` 對用戶端完全不開放；寫入一律經過 `security definer` 函式。

## 七、評分標準：建議由你接手的工作

1. **每個 Lv 的能力標準**：寫成可檢核的句子（例：Lv.1「能依現行規則回答，並辨識來源是否有效」）。目前的難度判斷依據寫在 `judge_difficulty.py`，不是公司的正式標準。
2. **出題藍圖**：規定每份考卷各主題幾題、紅線題最少幾題、選擇與簡答比例。現在只做到「盡量平均分散九個主題」，沒有保證紅線題數量。
3. **用實際作答校準**：上線前讓有經驗的人先考一輪，看每題答對率與鑑別度，檢查 Lv 分級是否合理；`attempt_answers` 已保存每題作答。
4. **簡答題評分**：目前只有員工自評＋主管覆核，沒有評分者校準。可考慮 AI 初評＋主管複評並保存評分理由；`rubric`、`key_error`、`reference_answer` 就是為此準備的。
5. **題目缺少「考哪個能力」的標籤**（規則理解、補問、情緒處理、權限判斷…），想分析新人弱點需要再加欄位。
6. **`rules_ext` 448 題與 `legacy` 252 題尚未人工審核**；審核流程已在主管後台（通過／刪除／還原），可逐步完成。
7. 綜合考核的**實務驗證、案例分享、主管確認**尚未有系統記錄。
8. **自評中途關頁**的考卷會停在 `pending_selfcheck`，不計入成績，也沒有「繼續自評」入口。
9. 權重與通過分（80／20、80／85／90）都是暫定值，存在 `assessments` 與 `_finalize_attempt` 的公式裡。

## 八、安全與使用規範

- 標準答案只存在資料庫，員工在交卷前拿不到；請維持這個原則，**不要把答案放進前端或公開 repo**。
- 管理者金鑰（service role／secret key）只能放在後端函式環境變數，不可出現在任何檔案。
- 部署前先跑 `適任考核系統/tools/check_site_safe.py`；Supabase 請關閉「Allow new users to sign up」。
"""


def build_package(out_dir, questions_json, xlsx_path, db_snapshot, setup_sql):
    out = Path(out_dir)
    if out.exists():
        shutil.rmtree(out)
    (out / "data").mkdir(parents=True)
    questions = json.loads(Path(questions_json).read_text(encoding="utf-8"))
    eq.export_csv(questions, str(out / "data" / "題庫_全部.csv"))
    (out / "data" / "題庫_全部.json").write_text(
        json.dumps(sorted(questions, key=lambda q: (q["stage"], q["id"])), ensure_ascii=False, indent=1), encoding="utf-8", newline="\n")

    for name in sheet_names(xlsx_path):
        _write_csv(out / "data" / "總表" / f"{name}.csv", read_rows(xlsx_path, name))

    rules = read_rows(xlsx_path, "規則總表")[1:]
    _write_csv(out / "data" / "案例對照_題目到總表規則.csv", _case_rows(bq.load_case_map(), rules),
               ["案例編號", "舊主題", "情境", "處理方式", "對應總表規則", "對應規則主題", "展開題數", "說明"])

    import judge_difficulty as jd
    drows = []
    for q in sorted(questions, key=lambda q: (q["difficulty"], q["id"])):
        e = jd.explain(q)
        drows.append([q["id"], f"Lv.{q['difficulty']}", e["依據"], e["情境複雜度"], e["問法"], q["stem"].replace("\n", " ")[:80]])
    _write_csv(out / "data" / "難度判斷對照.csv", drows, ["題號", "難度", "判斷依據", "情境複雜度", "問法", "題幹（前 80 字）"])

    db = json.loads(Path(db_snapshot).read_text(encoding="utf-8"))
    (out / "data" / "db_snapshot.json").write_text(json.dumps(db, ensure_ascii=False, indent=1), encoding="utf-8", newline="\n")
    (out / "schema").mkdir()
    shutil.copyfile(setup_sql, out / "schema" / "setup.sql")

    stats = _stats(questions)
    (out / "00_請先讀我.md").write_text(readme_text(stats, db), encoding="utf-8", newline="\n")
    return {"questions": stats["total"], "dir": str(out)}


def make_zip(pkg_dir, zip_path):
    pkg = Path(pkg_dir)
    Path(zip_path).parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(pkg.rglob("*")):
            if f.is_file():
                z.write(f, f"{TOP}/{f.relative_to(pkg).as_posix()}")
    return zip_path


if __name__ == "__main__":
    base = ROOT / "適任考核系統"
    out = base / "交接" / TOP
    q = base / "tools" / "out" / "questions.json"
    bq.main(str(q))
    info = build_package(str(out), str(q), str(ROOT / "統整結果_標準答案總表.xlsx"),
                         str(base / "tools" / "out" / "db_snapshot.json"), str(base / "supabase" / "setup.sql"))
    z = make_zip(str(out), str(base / "交接" / f"{TOP}.zip"))
    print(info["questions"], "題 →", out, "與", z)
