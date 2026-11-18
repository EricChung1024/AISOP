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
create function t_start(uid uuid, st int, ids text[]) returns jsonb language plpgsql as $$
begin
  reset role;
  delete from exam_papers where user_id = uid and stage = st;
  insert into exam_papers (user_id, stage, question_ids, status, locked_at) values (uid, st, ids, 'locked', now());
  perform t_as(uid);
  return start_exam(st);
end $$;
grant execute on function t_start(uuid, int, text[]) to public;




-- 取員工、主管、考卷
-- P1：主管產生草稿考卷：20 題、難度符合、主題平均、抽到的牌標記為 used；員工不能產生；同階段不能重複
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; boss uuid := 'aaaaaaaa-0000-0000-0000-000000000003'; pid uuid; g jsonb;
begin
  perform t_as(a);
  begin perform create_paper(a, 12); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'FORBIDDEN' then raise; end if; end;
  perform t_as(boss);
  begin perform create_paper(a, 10); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'BAD_STAGE' then raise; end if; end;
  begin perform create_paper(boss, 12); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'NOT_FOUND' then raise; end if; end;
  pid := create_paper(a, 12);
  g := get_paper(pid);
  assert g ->> 'status' = 'draft' and (g ->> 'count')::int = 20 and (g ->> 'total')::int = 20, '草稿 20 題';
  assert (select count(*) from jsonb_array_elements(g -> 'questions') q where (q ->> 'difficulty')::int = 1) = 20, '基礎考核全是 Lv.1';
  assert (select count(distinct q ->> 'stage') from jsonb_array_elements(g -> 'questions') q) = 9, '涵蓋九個主題';
  begin perform create_paper(a, 12); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'PAPER_EXISTS' then raise; end if; end;
  perform t_admin();
  assert (select count(*) from questions where used) = 20, '抽到的 20 張牌標記為已用';
end $$;

-- P2：員工在鎖定前看不到、不能考；也不能直接讀考卷表或呼叫主管函式
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; pid uuid;
begin
  perform t_as(a);
  assert my_papers() = '[]'::jsonb, '還沒鎖定，員工看不到考卷';
  begin perform start_exam(12); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'NO_PAPER' then raise; end if; end;
  begin perform count(*) from exam_papers; raise exception 'NO_RAISE';
  exception when insufficient_privilege then null; end;
  perform t_admin(); pid := (select id from exam_papers limit 1); perform t_as(a);
  begin perform get_paper(pid); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'FORBIDDEN' then raise; end if; end;
  reset role; set local role anon;
  begin perform my_papers(); raise exception 'NO_RAISE';
  exception when insufficient_privilege then null; end;
  reset role;
end $$;

-- P3：刪除 5 題 → 暫時移出；隨機補回 20 題，不會補到被刪的題；鎖定前題數不足不能鎖
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; boss uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
  pid uuid; ids text[]; gone text[]; g jsonb; n int;
begin
  perform t_admin(); pid := (select id from exam_papers where user_id = a and stage = 12 and status = 'draft');
  perform t_as(boss);
  g := get_paper(pid);
  gone := array(select q ->> 'id' from jsonb_array_elements(g -> 'questions') q limit 5);
  assert remove_from_paper(pid, gone) = 5, '刪除 5 題';
  g := get_paper(pid);
  assert (g ->> 'count')::int = 15, '剩 15 題';
  begin perform lock_paper(pid); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'PAPER_NOT_FULL' then raise; end if; end;
  perform t_admin();
  assert (select count(*) from questions where id = any (gone) and removed and not reviewed) = 5, '被刪的 5 題暫時移出隨機範圍';
  perform t_as(boss);
  assert refill_paper(pid) = 5, '隨機補 5 題';
  g := get_paper(pid);
  ids := array(select q ->> 'id' from jsonb_array_elements(g -> 'questions') q);
  assert array_length(ids, 1) = 20, '補回 20 題';
  assert not (ids && gone), '補的題不是剛刪掉的';
  assert (select count(*) from jsonb_array_elements(g -> 'questions') q where (q ->> 'difficulty')::int = 1) = 20, '補的題難度仍是 Lv.1';
  assert refill_paper(pid) = 0, '已滿 20 題不再補';
end $$;

-- P4：鎖定並出題 → 題目不能再改；員工看得到並能開始考；考完考卷標記為已使用
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; boss uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
  pid uuid; ids text[]; r jsonb; used_ids text[];
begin
  perform t_admin(); pid := (select id from exam_papers where user_id = a and stage = 12 and status = 'draft');
  ids := (select question_ids from exam_papers where id = pid);
  perform t_as(boss);
  perform lock_paper(pid);
  begin perform remove_from_paper(pid, array[ids[1]]); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'PAPER_LOCKED' then raise; end if; end;
  begin perform refill_paper(pid); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'PAPER_LOCKED' then raise; end if; end;
  perform t_admin();
  assert (select count(*) from questions where id = any (ids) and reviewed) = 20, '鎖定後這 20 題視為已審核';
  perform t_as(a);
  assert jsonb_array_length(my_papers()) = 1 and (my_papers() -> 0 ->> 'stage')::int = 12, '員工看到已出題的考卷';
  assert my_papers()::text not like '%question_ids%', '不外洩題目';
  r := start_exam(12);
  used_ids := array(select e ->> 'id' from jsonb_array_elements(r -> 'questions') e);
  assert (select array_agg(x order by x) from unnest(used_ids) x) = (select array_agg(x order by x) from unnest(ids) x), '考的就是鎖定的那 20 題';
  assert r::text not like '%correct_index%' and r::text not like '%explanation%', '不含答案';
  assert my_papers() = '[]'::jsonb, '考卷已使用';
  begin perform start_exam(12); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'NO_PAPER' then raise; end if; end;
  perform t_admin();
  assert (select status from exam_papers where id = pid) = 'used' and (select attempt_id from exam_papers where id = pid) is not null, '考卷標記為已使用並關聯考卷';
end $$;

-- P5：牌堆：抽過的題這一輪不再出現；牌堆抽完就重洗，被刪除的題放回
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; b uuid := 'aaaaaaaa-0000-0000-0000-000000000002'; boss uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
  p1 text[]; p2 text[]; p3 text[]; pid uuid; gone text[];
begin
  perform t_admin();
  p1 := (select question_ids from exam_papers where user_id = a and stage = 12 and status = 'used');
  perform t_as(boss);
  pid := create_paper(b, 12);
  perform t_admin(); p2 := (select question_ids from exam_papers where id = pid);
  assert not (p1 && p2), '第二份考卷不會抽到第一份已用過的題（牌堆沒抽完）';
  -- 目前 Lv.1 選擇題 50 張：已抽 40、其中被刪 5 張；牌堆剩 10 張，不夠 20 張 → 重洗
  assert (select count(*) from questions where difficulty = 1 and qtype = 'mcq' and removed) = 5, '重洗前有 5 張被暫時刪除';
  perform t_as(boss); perform discard_paper(pid);
  pid := create_paper(a, 12);
  perform t_admin(); p3 := (select question_ids from exam_papers where id = pid);
  assert array_length(p3, 1) = 20 and (select count(distinct x) from unnest(p3) x) = 20, '重洗後仍抽滿 20 張不重複';
  assert (select count(*) from questions where difficulty = 1 and qtype = 'mcq' and removed) = 0, '牌堆重洗：被刪除的牌放回';
  assert (select count(*) from questions where difficulty = 1 and qtype = 'mcq' and used) = 20, '新一輪：只有剛抽的 20 張是已用';
end $$;

-- P6：某難度的題庫不足時，由相鄰難度補滿（綜合考核：Lv.3 只有 2 題選擇＋4 題簡答）
do $$ declare a uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; boss uuid := 'aaaaaaaa-0000-0000-0000-000000000003'; pid uuid; g jsonb;
begin
  perform t_as(boss);
  pid := create_paper(a, 14);
  g := get_paper(pid);
  assert (g ->> 'count')::int = 20, '仍湊滿 20 題';
  assert (select count(*) from jsonb_array_elements(g -> 'questions') q where q ->> 'qtype' = 'short') = 3, '簡答最多 3 題';
  assert (select count(*) from jsonb_array_elements(g -> 'questions') q where (q ->> 'difficulty')::int = 3) >= 5, 'Lv.3 的題先抽';
  perform discard_paper(pid);
  begin perform discard_paper(pid); raise exception 'NO_RAISE';
  exception when others then if sqlerrm <> 'NOT_FOUND' then raise; end if; end;
end $$;

rollback;
