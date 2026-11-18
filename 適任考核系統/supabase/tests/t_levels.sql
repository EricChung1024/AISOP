begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@example.com', '{}'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'b@example.com', '{}'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'boss@example.com', '{}');
update profiles set role = 'supervisor' where id = 'aaaaaaaa-0000-0000-0000-000000000003';

-- 難度 1 題：45 題（散在 9 個主題，每主題 5 題，其中 3 題紅線）；難度 2 題：30 題；難度 3：4 題簡答＋2 題選擇；另有 5 題未審核的難度 1
insert into questions (id, stage, qtype, stem, options, correct_index, explanation, error_type, red_line, reviewed, difficulty)
select 'D1-' || n, 1 + n % 9, 'mcq', 'q' || n, '["a","b"]', 0, 'e', '用了舊規則', n <= 3, true, 1 from generate_series(1, 45) n;
insert into questions (id, stage, qtype, stem, options, correct_index, explanation, error_type, red_line, reviewed, difficulty)
select 'D2-' || n, 1 + n % 9, 'mcq', 'q' || n, '["a","b"]', 0, 'e', '用了舊規則', false, true, 2 from generate_series(1, 30) n;
insert into questions (id, stage, qtype, stem, options, correct_index, explanation, error_type, red_line, reviewed, difficulty)
select 'D3-' || n, 1 + n % 9, 'mcq', 'q' || n, '["a","b"]', 0, 'e', '用了舊規則', false, true, 3 from generate_series(1, 2) n;
insert into questions (id, stage, qtype, stem, correct_index, explanation, error_type, reference_answer, rubric, reviewed, difficulty)
select 'D3S-' || n, 1 + n % 9, 'short', 's' || n, null, 'e', '情境判斷失誤', 'ref', '["點一","點二"]', true, 3 from generate_series(1, 4) n;
insert into questions (id, stage, qtype, stem, options, correct_index, explanation, error_type, red_line, reviewed, difficulty)
select 'UN-' || n, 1 + n % 9, 'mcq', 'u' || n, '["a","b"]', 0, 'e', '用了舊規則', false, false, 1 from generate_series(1, 5) n;

create function t_as(uid uuid) returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;
create function t_admin() returns void language plpgsql as $$ begin reset role; end $$;
-- 前 k 題答對、其餘答錯
create function t_answers_k(att uuid, k int) returns jsonb language plpgsql as $$
declare out jsonb := '[]'; qq jsonb; q questions; pos int; orig int; n int := 0;
begin
  for qq in select e from jsonb_array_elements((select question_ids from attempts where id = att)) e loop
    n := n + 1;
    select * into q from questions where id = qq ->> 'id';
    orig := case when n <= k then q.correct_index else (q.correct_index + 1) % 2 end;
    select i - 1 into pos from jsonb_array_elements(qq -> 'perm') with ordinality t(v, i) where v::int = orig;
    out := out || jsonb_build_object('question_id', q.id, 'choice', pos);
  end loop;
  return out;
end $$;
grant execute on function t_as(uuid), t_admin(), t_answers_k(uuid, int) to public;
create function t_pool_small() returns void language sql security definer as $$
  update questions set removed = not (id in ('D1-1','D1-2','D1-3','D1-4','D1-5','D1-6','D1-7','D1-8')); $$;
grant execute on function t_pool_small() to public;



-- L1：設定表：舊階段停用、三階段 20 題、80／85／90 分
do $$ begin
  assert (select count(*) from assessments) = 15, '階段 0–14 共 15 筆設定';
  assert (select count(*) from assessments where active) = 3, '只有 3 個階段啟用（章節測驗已移除）';
  assert (select pass_score from assessments where stage = 12) = 80, '基礎考核 80 分';
  assert (select pass_score from assessments where stage = 13) = 85, '情境應用考核 85 分';
  assert (select pass_score from assessments where stage = 14) = 90, '綜合考核 90 分';
  assert (select count(*) from assessments where active and total_questions <> 20) = 0, '每人 20 題';
  assert (select due_months from assessments where stage = 14) = 6, '滿六個月';
  begin
    insert into attempts (user_id, stage, question_ids) values ('aaaaaaaa-0000-0000-0000-000000000001', 15, '[]');
    raise exception 'NO_RAISE';
  exception when check_violation then null; end;
end $$;

-- L1b：登入者可唯讀分級設定，但不能改；匿名什麼都看不到
do $$ begin
  perform t_as('aaaaaaaa-0000-0000-0000-000000000001');
  assert (select pass_score from v_assessments where stage = 14) = 90, 'view 可讀及格分';
  assert (select count(*) from v_assessments where active) = 3, 'view 可看出啟用的階段';
  begin update assessments set pass_score = 0; raise exception 'NO_RAISE';
  exception when insufficient_privilege then null; end;
  perform t_admin();
  set local role anon;
  begin perform count(*) from v_assessments; raise exception 'NO_RAISE';
  exception when insufficient_privilege then null; end;
  reset role;
end $$;

-- L2：舊階段（章節、試用期、半年）不能再開考
do $$ declare s int;
begin
  perform t_as('aaaaaaaa-0000-0000-0000-000000000001');
  foreach s in array array[0, 1, 5, 10, 11] loop
    begin perform start_exam(s); raise exception 'NO_RAISE';
    exception when others then if sqlerrm <> 'BAD_STAGE' then raise; end if; end;
  end loop;
end $$;

-- L3：每階段抽 20 題；難度符合階段；題目平均分散到九個主題；每次隨機
do $$ declare r jsonb; ids text[]; ids2 text[]; ok boolean := false;
begin
  perform t_as('aaaaaaaa-0000-0000-0000-000000000001');
  r := start_exam(12);
  assert jsonb_array_length(r -> 'questions') = 20 and (r ->> 'shortage')::int = 0, '基礎考核 20 題';
  ids := array(select e ->> 'id' from jsonb_array_elements(r -> 'questions') e);
  perform t_admin();
  assert (select count(*) from questions where id = any (ids) and difficulty = 1) = 20, '基礎考核全是難度 1';
  assert (select count(distinct stage) from questions where id = any (ids)) = 9, '20 題涵蓋九個主題';
  assert (select max(c) from (select count(*) c from questions where id = any (ids) group by stage) x) <= 3, '同一主題不超過 3 題';
  -- 隨機：連抽 10 次，題組不會每次都一樣
  perform t_as('aaaaaaaa-0000-0000-0000-000000000001');
  for i in 1..10 loop
    ids2 := array(select e ->> 'id' from jsonb_array_elements(start_exam(12) -> 'questions') e);
    if (select array_agg(x order by x) from unnest(ids) x) is distinct from (select array_agg(x order by x) from unnest(ids2) x) then ok := true; end if;
  end loop;
  assert ok, '每次抽題要隨機';
  r := start_exam(13);
  ids := array(select e ->> 'id' from jsonb_array_elements(r -> 'questions') e);
  perform t_admin();
  assert (select count(*) from questions where id = any (ids) and qtype = 'mcq' and difficulty = 2) = 18, '情境應用：18 題難度 2 選擇題';
  assert (select count(*) from questions where id = any (ids) and qtype = 'short') = 2, '情境應用：2 題簡答（難度 2 沒有簡答，取最近難度）';
end $$;

-- L3b：難度 3 的題庫不足 20 題時，由相鄰難度補；仍不足會回報 shortage
do $$ declare r jsonb; ids text[];
begin
  perform t_as('aaaaaaaa-0000-0000-0000-000000000001');
  r := start_exam(14);
  ids := array(select e ->> 'id' from jsonb_array_elements(r -> 'questions') e);
  assert jsonb_array_length(r -> 'questions') = 20, '綜合考核仍湊滿 20 題';
  perform t_admin();
  assert (select count(*) from questions where id = any (ids) and difficulty = 3) = 5, '難度 3 的 2 題選擇＋3 題簡答優先抽';
  assert (select count(*) from questions where id = any (ids) and qtype = 'short') = 3, '簡答最多 3 題';
  perform t_pool_small();
  perform t_as('aaaaaaaa-0000-0000-0000-000000000001');
  r := start_exam(12);
  assert jsonb_array_length(r -> 'questions') = 8 and (r ->> 'shortage')::int = 12, '題庫不足時回報缺 12 題';
end $$;

-- L4：及格門檻：同樣 17／20 答對（85 分）→ 基礎 80 及格、情境 85 及格、綜合 90 不及格
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; att uuid; ans jsonb; r jsonb;
begin
  reset role; update questions set removed = false;
  perform t_as(a); att := (start_exam(12) ->> 'attempt_id')::uuid;
  perform t_admin(); ans := t_answers_k(att, 17); perform t_as(a);
  r := submit_exam(att, ans);
  assert (r ->> 'score')::numeric = 85, '17/20 ＝ 85 分';
  assert (r ->> 'pass_score')::numeric = 80, '結果帶該階段及格分';
end $$;

-- L5：紅線題答錯，即使總分達標也不及格
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; att uuid; ans jsonb; r jsonb; red text;
begin
  reset role; delete from questions where id like 'D%' and not (id like 'D1-%');
  update questions set red_line = false;
  update questions set red_line = true, shuffle = false where id = 'D1-1';
  perform t_as(a); att := (start_exam(12) ->> 'attempt_id')::uuid;
  perform t_admin();
  -- 全部答對，只把紅線題答錯（若本次沒抽到紅線題就重抽）
  while not exists (select 1 from attempts at, jsonb_array_elements(at.question_ids) e where at.id = att and e ->> 'id' = 'D1-1') loop
    perform t_as(a); att := (start_exam(12) ->> 'attempt_id')::uuid; perform t_admin();
  end loop;
  select jsonb_agg(case when x ->> 'question_id' = 'D1-1' then jsonb_build_object('question_id', 'D1-1', 'choice', 1) else x end)
    into ans from jsonb_array_elements(t_answers_k(att, 20)) x;
  perform t_as(a);
  r := submit_exam(att, ans);
  assert (r ->> 'score')::numeric = 95, '19/20 ＝ 95 分，高於及格線';
  assert not (r ->> 'passed')::bool and (r ->> 'red_line_failed')::bool, '紅線題答錯：不能用其他題的高分抵銷';
end $$;

-- L6：考核日期：滿 N 個月同日；沒有同日採月底；週末順延到下一個工作日（不用 30／90／180 天）
do $$ begin
  assert exam_due_date(date '2026-01-05', 1) = date '2026-02-05', '1/5 → 2/5（週四）';
  assert exam_due_date(date '2026-01-31', 1) = date '2026-03-02', '1/31 → 月底 2/28（週六）→ 順延到 3/2 週一';
  assert exam_due_date(date '2026-08-31', 6) = date '2027-03-01', '8/31 → 月底 2/28（週日）→ 順延到 3/1 週一';
  assert exam_due_date(date '2026-02-28', 3) = date '2026-05-28', '2/28 → 5/28（週四）';
  assert exam_due_date(date '2026-03-14', 3) = date '2026-06-15', '6/14 週日 → 6/15 週一';
end $$;

-- L7：等級依年資、不看是否通過；各階段通過狀態
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
begin
  perform t_as('aaaaaaaa-0000-0000-0000-000000000003');
  perform set_hire_date(a, (current_date - interval '15 days')::date);
  assert (select level from v_exam_schedule where user_id = a) = 1, '未滿一個月 Lv.1';
  perform set_hire_date(a, (current_date - interval '2 months')::date);
  assert (select level from v_exam_schedule where user_id = a) = 2, '滿一個月未滿三個月 Lv.2（沒通過基礎考核也升等）';
  perform set_hire_date(a, (current_date - interval '4 months')::date);
  assert (select level from v_exam_schedule where user_id = a) = 3, '滿三個月 Lv.3';
  assert (select passed_1 from v_exam_schedule where user_id = a) is not null, '有通過狀態欄位';
  assert (select count(*) from v_exam_schedule) = 2, '主管看得到全部員工';
  perform t_as('aaaaaaaa-0000-0000-0000-000000000002');
  assert (select count(*) from v_exam_schedule) = 1, '員工只看得到自己';
  assert (select level from v_exam_schedule) is null, '沒有到職日 → 無等級';
  begin perform set_hire_date('aaaaaaaa-0000-0000-0000-000000000002', null); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'FORBIDDEN' then raise; end if; end;
end $$;

-- L8：主管刪除題目：之後不會被抽到，資料保留（不歸檔）；可還原；員工不能刪
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; att uuid; r jsonb; ids text[];
begin
  perform t_as(a);
  begin perform remove_questions(array['D1-2']); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'FORBIDDEN' then raise; end if; end;
  perform t_admin(); update questions set removed = false;
  perform t_as('aaaaaaaa-0000-0000-0000-000000000003');
  assert remove_questions(array['D1-2', 'D1-5']) = 2, '刪除 2 題';
  assert remove_questions(array['D1-2']) = 0, '重複刪除不重複計';
  assert (select count(*) from jsonb_array_elements(list_questions_for_review(null, null, 1)) ) = 48, '審核清單預設不含已刪除';
  assert (select count(*) from jsonb_array_elements(list_questions_for_review(null, null, 1, true)) ) = 2, '可列出已刪除';
  perform t_as(a);
  for i in 1..15 loop
    ids := array(select e ->> 'id' from jsonb_array_elements(start_exam(12) -> 'questions') e);
    assert not ('D1-2' = any (ids) or 'D1-5' = any (ids)), '已刪除的題目不得再出現';
  end loop;
  perform t_admin();
  assert (select count(*) from questions where id in ('D1-2', 'D1-5')) = 2, '資料仍保留';
  assert (select reviewed from questions where id = 'D1-2') = false, '刪除時一併取消審核';
  perform t_as('aaaaaaaa-0000-0000-0000-000000000003');
  assert restore_questions(array['D1-2']) = 1, '還原 1 題';
  -- 審核一份考卷用到的題目
  perform t_as(a); att := (start_exam(12) ->> 'attempt_id')::uuid;
  perform t_as('aaaaaaaa-0000-0000-0000-000000000003');
  assert jsonb_array_length(list_attempt_questions(att)) = 20, '主管可看一份考卷的 20 題與答案';
  perform t_as(a);
  begin perform list_attempt_questions(att); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'FORBIDDEN' then raise; end if; end;
end $$;

rollback;
