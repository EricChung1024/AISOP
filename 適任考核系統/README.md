# 適任考核系統

好物集客服的「適任評估考核」網站（資料全為虛構）。員工考試、看成績與錯誤類型、用錯題區檢討；主管看全員成績、錯誤類型、考核期限。

- 前端：純靜態 HTML／JS（`site/`），放 GitHub Pages。
- 後端：Supabase（登入、資料庫、權限規則、評分函式）。標準答案只在資料庫，員工交卷後才拿得到。

## 一、第一次設定 Supabase（只做一次）

1. **建立資料表與函式**：Supabase 後台 → SQL Editor → 貼上 `supabase/setup.sql` → Run。
2. **匯入題庫**（含標準答案，只在你的電腦上產生，不要放上網站）：
   ```
   python -X utf8 -I 適任考核系統/tools/build_questions.py 適任考核系統/tools/out/questions.json
   python -X utf8 -I 適任考核系統/tools/gen_seed_sql.py 適任考核系統/tools/out/questions.json 適任考核系統/supabase/seed.sql
   ```
   把 `supabase/seed.sql` 的內容貼進 SQL Editor 執行（檔案較大，貼不下可分段，每段以 `insert into questions` 開頭、`;` 結尾）。
   完成後執行 `select stage, count(*) from questions group by 1 order by 1;`，確認 1–9 章都有題。
3. **登入設定**：Authentication → Providers → Email，建議關閉「Confirm email」（帳號都由主管建立）。
4. **網址設定**：Authentication → URL Configuration → Site URL 填 GitHub Pages 網址。
5. **網站連線設定**：`site/js/config.js` 已填入專案網址與 publishable key（這把 key 設計上就是公開的）。

## 二、建立帳號

- Authentication → Users → **Add user**：填信箱與密碼，勾「Auto Confirm User」，User Metadata 填 `{"name": "王小明"}`（顯示姓名）。
- 新帳號預設是**員工**。設為**主管**（在 SQL Editor 執行）：
  ```sql
  update profiles set role = 'supervisor'
   where id = (select id from auth.users where email = 'boss@example.com');
  ```
- **到職日**：主管登入後，在「員工詳情」頁設定（用來算試用期與半年考核期限）。

## 三、考核分級與調整

| 級別 | 階段 | 題數 | 及格 | 說明 |
|---|---|---|---|---|
| 章節考核 | 1–9 | 10 | 80 | 隨時練習／考核 |
| 綜合適任考核 | 0 | 30 | 80 | 全部已審核題 |
| 試用期考核 | 10 | 30 | 80 | 至少 5 題紅線題；期限＝到職日＋3 個月 |
| 半年考核 | 11 | 40 | 85 | 至少 10 題紅線題；每半年一次 |

要調整題數、及格分、紅線題保底：直接改設定表，不用改程式，例如
`update assessments set pass_score = 90 where stage = 11;`

## 四、題庫審核

舊題庫標示「示範題，待公司主管審核」，且是通用電商版本。主管在「主管後台 → 題庫審核」確認題目符合好物集 SOP 後，勾選並標為已審核。**未審核的題目不會進入綜合、試用期、半年考核**，只會出現在各章考核。

## 五、匯出全部題目

```
python -X utf8 -I 適任考核系統/tools/export_questions.py 適任考核系統/tools/out/questions.json 適任考核系統/題庫匯出/題庫總表.csv
```
用 Excel 開啟（UTF-8 含 BOM，中文不會亂碼）。內容含標準答案，**請勿放上公開網站或公開 repo**（`題庫匯出/` 已加入 .gitignore）。

## 六、部署

只把 `site/` 的內容放進網站 repo（不要放題庫、`seed.sql`、`tools/`）。部署前先檢查：
```
python -X utf8 -I 適任考核系統/tools/check_site_safe.py 適任考核系統/site
```
輸出 `OK` 才能發佈。檢查項目：沒有 secret／管理者金鑰、沒有非 anon 的 JWT、沒有題庫答案檔。

## 七、本機測試

| 指令 | 內容 |
|---|---|
| `python -X utf8 -I -m unittest discover -s 適任考核系統/tools/tests` | 題庫產生、匯出、安全檢查 |
| `node 適任考核系統/runner/run_sql_tests.mjs` | 資料庫權限與評分（本機 Postgres） |
| `node --test "適任考核系統/site/js/*.test.js"` | 前端純函式 |
| `node 適任考核系統/runner/e2e.mjs` | 真實 Chrome 端對端（含員工／主管流程） |

端對端與 SQL 測試跑在本機的 Postgres（pglite）與模擬後端上；**正式環境仍要依下列清單驗收一次**。

## 八、正式環境驗收清單

1. 員工登入 → 首頁；手動輸入 `supervisor.html` → 被導回首頁。主管登入 → 員工總覽。
2. 員工考一次章節考核：交卷後才看到答案與解析；開發者工具 Network 看 `start_exam` 回應，確認**沒有** `correct_index`、`explanation`、`reference_answer`。
3. 故意答錯 → 錯題區出現該題；重練連續答對 2 次 → 已掌握。
4. 員工用開發者工具呼叫 `set_reviewed` → 回 `FORBIDDEN`；員工直接讀 `questions` 表 → 被拒絕。
5. 主管設到職日 → 員工首頁顯示試用期／半年期限。
6. 員工乙看不到員工甲的成績與錯題。
