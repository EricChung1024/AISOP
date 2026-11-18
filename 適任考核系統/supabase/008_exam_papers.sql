-- 考卷流程：先抽題成草稿 → 主管審核（暫時刪除不合適的題）→ 隨機補到 20 題 → 鎖定並出題 → 新人才能開始考。
-- 取代「新人按開始考試就直接抽題」。題庫像牌堆：抽過的題目這一輪不再被抽到（used），刪除＝暫時抽出放一邊（removed）；
-- 牌堆抽完時，所有牌（含已刪除的）重新洗回去，開始新一輪（不歸檔）。
-- 新增錯誤碼：NO_PAPER（還沒出題）、PAPER_EXISTS、PAPER_NOT_FULL、PAPER_LOCKED。

create table exam_papers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  stage int not null references assessments (stage),
  question_ids text[] not null default '{}',          -- 考卷上的題目（依序）
  rejected_ids text[] not null default '{}',          -- 這份考卷被主管刪掉的題目，不會再補回同一份考卷
  status text not null default 'draft' check (status in ('draft', 'locked', 'used')),
  created_by uuid references profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  locked_at timestamptz,
  attempt_id uuid references attempts (id) on delete set null
);
create unique index exam_papers_open_idx on exam_papers (user_id, stage) where status in ('draft', 'locked');
-- 和 questions 一樣：啟用 RLS 且不建任何 policy，用戶端不能直接讀寫（題目編號也不外洩）
alter table exam_papers enable row level security;
revoke all on exam_papers from anon, authenticated;

-- ===== 牌堆標記 =====
-- used：這一輪已被抽進某份考卷，不再被抽到；牌堆抽完重洗時清除
alter table questions add column used boolean not null default false;

-- ===== 內部：抽題 =====
-- 只從指定難度（p_only_diff）或離 p_near 最近的難度抽；同難度內依主題輪流再隨機
create function _pick(p_short boolean, p_n int, p_exclude text[], p_only_diff int default null, p_near int default null)
returns text[] language sql security definer set search_path = public as $$
  select coalesce(array(
    select id from (
      select id, row_number() over (order by abs(difficulty - coalesce(p_near, p_only_diff, 2)), rn, random()) as pos from (
        select id, difficulty, row_number() over (partition by stage, difficulty order by random()) as rn
          from questions
         where (qtype = 'short') = p_short and not removed and not used and not (id = any (p_exclude))
           and (p_only_diff is null or difficulty = p_only_diff)) c
    ) o order by pos limit greatest(p_n, 0)), '{}'::text[]);
$$;

-- 抽滿 p_n 題：先抽指定難度、這一輪還沒抽過的牌；不夠就重洗（該難度同題型的牌全部放回，含已刪除的）再抽；仍不夠才抽相鄰難度。
-- 抽到的牌標記為 used。
create function _fill(p_short boolean, p_n int, p_diff int, p_exclude text[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare ids text[];
begin
  ids := _pick(p_short, p_n, p_exclude, p_diff, null);
  if coalesce(array_length(ids, 1), 0) < p_n then
    update questions set removed = false, removed_at = null, removed_by = null, used = false
     where difficulty = p_diff and (qtype = 'short') = p_short and (removed or used);
    ids := ids || _pick(p_short, p_n - coalesce(array_length(ids, 1), 0), p_exclude || ids, p_diff, null);
  end if;
  if coalesce(array_length(ids, 1), 0) < p_n then
    ids := ids || _pick(p_short, p_n - coalesce(array_length(ids, 1), 0), p_exclude || ids, null, p_diff);
  end if;
  update questions set used = true where id = any (ids);
  return ids;
end $$;

-- ===== 主管：考卷 =====
create function create_paper(p_user uuid, p_stage int) returns uuid
language plpgsql security definer set search_path = public as $$
declare cfg assessments; v_short int; v_ids text[]; v_id uuid;
begin
  perform _require_supervisor();
  select * into cfg from assessments where stage = p_stage and active;
  if not found then raise exception 'BAD_STAGE'; end if;
  if not exists (select 1 from profiles where id = p_user and role = 'employee') then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from exam_papers where user_id = p_user and stage = p_stage and status in ('draft', 'locked')) then
    raise exception 'PAPER_EXISTS';
  end if;
  select least(cfg.short_max, count(*)) into v_short from questions where qtype = 'short' and not removed;
  v_ids := _fill(false, cfg.total_questions - v_short, cfg.difficulty, '{}') || _fill(true, v_short, cfg.difficulty, '{}');
  if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'NO_QUESTIONS'; end if;
  insert into exam_papers (user_id, stage, question_ids, created_by) values (p_user, p_stage, v_ids, auth.uid()) returning id into v_id;
  return v_id;
end $$;

create function get_paper(p_paper uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pp exam_papers; cfg assessments;
begin
  perform _require_supervisor();
  select * into pp from exam_papers where id = p_paper;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into cfg from assessments where stage = pp.stage;
  return jsonb_build_object(
    'id', pp.id, 'user_id', pp.user_id, 'user_name', (select name from profiles where id = pp.user_id),
    'stage', pp.stage, 'status', pp.status, 'total', cfg.total_questions, 'short_max', cfg.short_max,
    'difficulty', cfg.difficulty, 'count', coalesce(array_length(pp.question_ids, 1), 0), 'locked_at', pp.locked_at,
    'questions', (select coalesce(jsonb_agg(to_jsonb(q) order by u.ord), '[]'::jsonb)
                    from unnest(pp.question_ids) with ordinality u(qid, ord) join questions q on q.id = u.qid));
end $$;

create function list_papers(p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _require_supervisor();
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', e.id, 'user_id', e.user_id, 'user_name', p.name, 'stage', e.stage, 'status', e.status,
            'count', coalesce(array_length(e.question_ids, 1), 0), 'created_at', e.created_at, 'locked_at', e.locked_at)
          order by e.created_at desc), '[]'::jsonb)
            from exam_papers e join profiles p on p.id = e.user_id
           where p_user is null or e.user_id = p_user);
end $$;

-- 刪除題目：從這份草稿拿掉，暫時抽出放一邊（不歸檔；牌堆抽完重洗時會放回）
create function remove_from_paper(p_paper uuid, p_ids text[]) returns int
language plpgsql security definer set search_path = public as $$
declare pp exam_papers; n int;
begin
  perform _require_supervisor();
  select * into pp from exam_papers where id = p_paper for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if pp.status <> 'draft' then raise exception 'PAPER_LOCKED'; end if;
  n := (select count(*) from unnest(pp.question_ids) x where x = any (p_ids));
  update exam_papers set question_ids = array(select x from unnest(pp.question_ids) x where not (x = any (p_ids))),
                         rejected_ids = rejected_ids || array(select x from unnest(p_ids) x where x = any (pp.question_ids))
   where id = p_paper;
  update questions set removed = true, removed_at = now(), removed_by = auth.uid(), reviewed = false
   where id = any (p_ids) and id = any (pp.question_ids) and not removed;
  return n;
end $$;

-- 隨機補到該階段的題數（簡答題先補到上限）
create function refill_paper(p_paper uuid) returns int
language plpgsql security definer set search_path = public as $$
declare pp exam_papers; cfg assessments; need int; cur_short int; v_short int; add_short text[]; add_mcq text[];
begin
  perform _require_supervisor();
  select * into pp from exam_papers where id = p_paper for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if pp.status <> 'draft' then raise exception 'PAPER_LOCKED'; end if;
  select * into cfg from assessments where stage = pp.stage;
  need := cfg.total_questions - coalesce(array_length(pp.question_ids, 1), 0);
  if need <= 0 then return 0; end if;
  select count(*) into cur_short from questions where id = any (pp.question_ids) and qtype = 'short';
  v_short := greatest(0, least(cfg.short_max - cur_short, need));
  add_short := _fill(true, v_short, cfg.difficulty, pp.question_ids || pp.rejected_ids);
  add_mcq := _fill(false, need - coalesce(array_length(add_short, 1), 0), cfg.difficulty,
                   pp.question_ids || pp.rejected_ids || add_short);
  update exam_papers set question_ids = pp.question_ids || add_short || add_mcq where id = p_paper;
  return coalesce(array_length(add_short, 1), 0) + coalesce(array_length(add_mcq, 1), 0);
end $$;

-- 鎖定並出題：題目數要等於該階段題數（題庫實在不夠時才可 p_allow_short）；鎖定後題目視為已審核
create function lock_paper(p_paper uuid, p_allow_short boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare pp exam_papers; cfg assessments;
begin
  perform _require_supervisor();
  select * into pp from exam_papers where id = p_paper for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if pp.status <> 'draft' then raise exception 'PAPER_LOCKED'; end if;
  select * into cfg from assessments where stage = pp.stage;
  if coalesce(array_length(pp.question_ids, 1), 0) = 0
     or (coalesce(array_length(pp.question_ids, 1), 0) < cfg.total_questions and not p_allow_short) then
    raise exception 'PAPER_NOT_FULL';
  end if;
  update exam_papers set status = 'locked', locked_at = now() where id = p_paper;
  update questions set reviewed = true where id = any (pp.question_ids);
end $$;

-- 捨棄尚未使用的考卷（草稿或已鎖定但新人還沒開始考）
create function discard_paper(p_paper uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_supervisor();
  delete from exam_papers where id = p_paper and status in ('draft', 'locked');
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- ===== 員工：看有哪些已出題的考卷；開始考試改用已鎖定的考卷 =====
create function my_papers() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('paper_id', id, 'stage', stage, 'locked_at', locked_at) order by locked_at), '[]'::jsonb)
    from exam_papers where user_id = auth.uid() and status = 'locked';
$$;

create or replace function start_exam(p_stage int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); cfg assessments; pp exam_papers; q questions; perm int[];
  v_qids jsonb := '[]'::jsonb; v_client jsonb := '[]'::jsonb; v_att uuid;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into cfg from assessments where stage = p_stage and active;
  if not found then raise exception 'BAD_STAGE'; end if;
  select * into pp from exam_papers where user_id = v_uid and stage = p_stage and status = 'locked' for update;
  if not found then raise exception 'NO_PAPER'; end if;

  for q in select * from questions where id = any (pp.question_ids) order by random() loop
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
  update exam_papers set status = 'used', attempt_id = v_att where id = pp.id;
  return jsonb_build_object('attempt_id', v_att, 'stage', p_stage, 'questions', v_client,
                            'shortage', greatest(cfg.total_questions - jsonb_array_length(v_qids), 0));
end $$;

revoke all on function _pick(boolean, int, text[], int, int), _fill(boolean, int, int, text[]) from public, anon, authenticated;
revoke all on function create_paper(uuid, int), get_paper(uuid), list_papers(uuid), remove_from_paper(uuid, text[]), refill_paper(uuid),
  lock_paper(uuid, boolean), discard_paper(uuid), my_papers() from public, anon;
grant execute on function create_paper(uuid, int), get_paper(uuid), list_papers(uuid), remove_from_paper(uuid, text[]), refill_paper(uuid),
  lock_paper(uuid, boolean), discard_paper(uuid), my_papers() to authenticated;
