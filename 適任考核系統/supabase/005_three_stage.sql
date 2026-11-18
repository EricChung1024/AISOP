-- 三階段考核（滿 1／3／6 個月）、移除章節測驗、難易度分級抽題、主管審核與刪除題目。
-- 舊階段（0–11）與既有考卷、作答、錯題資料全部保留唯讀，只是不能再開考（active = false）。
-- 錯誤碼新增：BAD_STAGE（階段已停用也用這個）。

-- ===== 一、考核設定 =====
alter table assessments drop constraint assessments_stage_check;
alter table assessments add constraint assessments_stage_check check (stage between 0 and 14);
alter table assessments drop constraint assessments_kind_check;
alter table assessments add constraint assessments_kind_check
  check (kind in ('chapter', 'comprehensive', 'probation', 'semiannual', 'foundation', 'scenario', 'integrated'));
alter table attempts drop constraint attempts_stage_check;
alter table attempts add constraint attempts_stage_check check (stage between 0 and 14);

alter table assessments add column active boolean not null default true;      -- false＝停用（舊階段）
alter table assessments add column difficulty int check (difficulty in (1, 2, 3));  -- 抽題難度；舊階段為 null
alter table assessments add column due_months int;                            -- 到職滿幾個月考核

update assessments set active = false where stage between 0 and 11;
insert into assessments (stage, name, kind, total_questions, short_max, pass_score, red_min, interval_months, difficulty, due_months) values
  (12, '基礎考核（滿 1 個月）',   'foundation', 20, 0, 80, 0, null, 1, 1),
  (13, '情境應用考核（滿 3 個月）', 'scenario',   20, 2, 85, 0, null, 2, 3),
  (14, '綜合考核（滿 6 個月）',   'integrated', 20, 3, 90, 0, null, 3, 6);

-- ===== 二、題庫：難度、刪除標記 =====
-- difficulty：1 基礎（規則、流程、來源辨識）、2 情境應用（資料不足、條件改變、追問、情緒）、3 綜合（跨主題、客訴、補償、交接）
-- removed：主管刪除。刪除的題目不再被抽題，但資料保留（暫不歸檔，也不真的刪列，避免弄壞歷史考卷）。
alter table questions add column difficulty int check (difficulty in (1, 2, 3));
alter table questions add column removed boolean not null default false;
alter table questions add column removed_at timestamptz;
alter table questions add column removed_by uuid references profiles (id) on delete set null;

-- 既有題目的預設難度（依來源與題型的暫定對應，主管審核時可再調整）：
--   總表規則題 → 1；舊題依總表改寫（rules_ext）→ 2；舊通用題（legacy）簡答 → 3、其餘 → 2；AI 新題由出題時指定。
update questions set difficulty = case
  when source = 'rules' then 1
  when source = 'rules_ext' then 2
  when qtype = 'short' then 3
  else 2 end
where difficulty is null;
alter table questions alter column difficulty set not null;
alter table questions alter column difficulty set default 1;
create index questions_pool_idx on questions (difficulty) where not removed;

-- ===== 三、考核日期：滿 N 個月同日；當月沒有同日採月底；遇週末順延到下一個工作日 =====
-- 只處理週六、週日；國定假日目前沒有資料表，需要時由主管直接改到職日或另建假日表。
create function exam_due_date(p_hire date, p_months int) returns date
language plpgsql immutable as $$
declare d date := (p_hire + make_interval(months => p_months))::date;  -- 1/31 + 1 個月 ＝ 2/28（月底）
begin
  while extract(dow from d) in (0, 6) loop d := d + 1; end loop;
  return d;
end $$;

-- 每位員工的三次考核日期、目前等級（年資到期即升等，不看考核結果）與各階段通過情形
create view v_exam_schedule with (security_invoker = true) as
select p.id as user_id, p.name, p.hire_date,
       exam_due_date(p.hire_date, 1) as due_1, exam_due_date(p.hire_date, 3) as due_3, exam_due_date(p.hire_date, 6) as due_6,
       case when p.hire_date is null then null
            when current_date < (p.hire_date + interval '1 month')::date then 1
            when current_date < (p.hire_date + interval '3 months')::date then 2
            else 3 end as level,
       exists (select 1 from attempts a where a.user_id = p.id and a.stage = 12 and a.passed) as passed_1,
       exists (select 1 from attempts a where a.user_id = p.id and a.stage = 13 and a.passed) as passed_2,
       exists (select 1 from attempts a where a.user_id = p.id and a.stage = 14 and a.passed) as passed_3
from profiles p
where p.role = 'employee';
grant select on v_exam_schedule to authenticated;

-- ===== 四、抽題：每人 20 題，依該階段的難度隨機抽，題目盡量平均分到九個主題 =====
-- 不夠的題數從相鄰難度補；仍不足則回傳實際題數，並在 shortage 說明缺幾題（供出題函式補題）。
create or replace function start_exam(p_stage int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); cfg assessments; v_short_n int; v_choice_n int; v_ids text[];
  q questions; perm int[]; v_qids jsonb := '[]'::jsonb; v_client jsonb := '[]'::jsonb; v_att uuid; v_missing int;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into cfg from assessments where stage = p_stage and active;
  if not found then raise exception 'BAD_STAGE'; end if;

  select least(cfg.short_max, count(*)) into v_short_n from questions
   where qtype = 'short' and not removed;
  v_choice_n := cfg.total_questions - v_short_n;

  -- 排序：相同難度優先、其次較近的難度；同難度內依主題輪流（每個主題先各取一題）再隨機
  v_ids := array(
    select id from (
      select id, row_number() over (order by abs(difficulty - cfg.difficulty), rn, random()) as pos from (
        select id, difficulty, row_number() over (partition by stage, difficulty order by random()) as rn
          from questions where qtype <> 'short' and not removed) c
    ) o order by pos limit v_choice_n)
  || array(
    select id from (
      select id, row_number() over (order by abs(difficulty - cfg.difficulty), rn, random()) as pos from (
        select id, difficulty, row_number() over (partition by stage, difficulty order by random()) as rn
          from questions where qtype = 'short' and not removed) c
    ) o order by pos limit v_short_n);
  if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'NO_QUESTIONS'; end if;
  v_missing := cfg.total_questions - array_length(v_ids, 1);

  for q in select * from questions where id = any (v_ids) order by random() loop
    if q.qtype = 'mcq' and q.shuffle then
      perm := array(select g - 1 from generate_series(1, jsonb_array_length(q.options)) g order by random());
    elsif q.qtype in ('mcq', 'tf') then
      perm := array(select g - 1 from generate_series(1, jsonb_array_length(q.options)) g order by g);
    else
      perm := null;
    end if;
    v_qids := v_qids || jsonb_build_object('id', q.id, 'perm', to_jsonb(perm));
    v_client := v_client || jsonb_build_object(
      'id', q.id, 'qtype', q.qtype, 'stem', q.stem,
      'options', case when perm is null then null
                      else (select jsonb_agg(q.options -> p order by ord) from unnest(perm) with ordinality u(p, ord)) end);
  end loop;

  insert into attempts (user_id, stage, question_ids) values (v_uid, p_stage, v_qids) returning id into v_att;
  return jsonb_build_object('attempt_id', v_att, 'stage', p_stage, 'questions', v_client, 'shortage', v_missing);
end $$;

-- ===== 五、結算：紅線題不能用其他題的高分抵銷 =====
create or replace function _finalize_attempt(p_attempt uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  mcq_total int; mcq_right int; short_total int; short_pts numeric; v_score numeric; v_passed boolean; v_pass numeric;
  v_red_fail boolean;
begin
  select count(*) filter (where q.qtype <> 'short'),
         count(*) filter (where q.qtype <> 'short' and aa.is_correct),
         count(*) filter (where q.qtype = 'short'),
         coalesce(sum(aa.points) filter (where q.qtype = 'short'), 0),
         coalesce(bool_or(q.red_line and (case when q.qtype = 'short' then coalesce(aa.points, 0) < 1
                                               else not coalesce(aa.is_correct, false) end)), false)
    into mcq_total, mcq_right, short_total, short_pts, v_red_fail
  from attempt_answers aa join questions q on q.id = aa.question_id
  where aa.attempt_id = p_attempt;

  v_score := case
    when mcq_total > 0 and short_total > 0 then 100 * (0.8 * mcq_right / mcq_total + 0.2 * short_pts / short_total)
    when mcq_total > 0 then 100.0 * mcq_right / mcq_total
    when short_total > 0 then 100 * short_pts / short_total
    else 0 end;
  v_score := round(v_score, 1);
  select pass_score into v_pass from assessments where stage = (select stage from attempts where id = p_attempt);
  v_passed := v_score >= coalesce(v_pass, 80) and not v_red_fail;
  update attempts set score = v_score, passed = v_passed, status = 'done', submitted_at = coalesce(submitted_at, now()) where id = p_attempt;
  return jsonb_build_object('status', 'done', 'attempt_id', p_attempt, 'score', v_score,
                            'passed', v_passed, 'pass_score', coalesce(v_pass, 80), 'red_line_failed', v_red_fail,
                            'items', _attempt_report(p_attempt));
end $$;

-- ===== 六、主管審核與刪除 =====
-- 一份考卷用到的題目（含答案與審核狀態），讓資深成員在新人考完後逐題 review
create function list_attempt_questions(p_attempt uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _require_supervisor();
  return (select coalesce(jsonb_agg(to_jsonb(q) order by q.id), '[]'::jsonb)
            from questions q
           where q.id in (select e ->> 'id' from attempts a, jsonb_array_elements(a.question_ids) e where a.id = p_attempt));
end $$;

-- 刪除題目：從此不再被抽到（保留資料，不歸檔）。已刪除的題目也不會再出現在錯題區重練。
create function remove_questions(p_ids text[]) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _require_supervisor();
  update questions set removed = true, removed_at = now(), removed_by = auth.uid(), reviewed = false
   where id = any (p_ids) and not removed;
  get diagnostics n = row_count;
  return n;
end $$;

create function restore_questions(p_ids text[]) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _require_supervisor();
  update questions set removed = false, removed_at = null, removed_by = null where id = any (p_ids) and removed;
  get diagnostics n = row_count;
  return n;
end $$;

-- 審核清單：新增難度與刪除篩選（預設不含已刪除）
drop function list_questions_for_review(int, boolean);
create function list_questions_for_review(p_stage int default null, p_reviewed boolean default null,
                                          p_difficulty int default null, p_removed boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _require_supervisor();
  return (select coalesce(jsonb_agg(to_jsonb(q) order by q.stage, q.id), '[]'::jsonb)
            from questions q
           where (p_stage is null or q.stage = p_stage) and (p_reviewed is null or q.reviewed = p_reviewed)
             and (p_difficulty is null or q.difficulty = p_difficulty) and q.removed = p_removed);
end $$;

revoke all on function exam_due_date(date, int), list_attempt_questions(uuid), remove_questions(text[]), restore_questions(text[]),
  list_questions_for_review(int, boolean, int, boolean) from public, anon;
grant execute on function exam_due_date(date, int), list_attempt_questions(uuid), remove_questions(text[]), restore_questions(text[]),
  list_questions_for_review(int, boolean, int, boolean) to authenticated;

-- 前端用的分級設定檢視：新增是否啟用、難度、考核月數（只能在欄位尾端追加）
create or replace view v_assessments with (security_invoker = true) as
select stage, name, kind, total_questions, pass_score, interval_months, active, difficulty, due_months from assessments;
