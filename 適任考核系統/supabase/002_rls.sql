-- 權限：全部資料表啟用 RLS，用戶端只能 select；寫入只經 security definer 的 RPC。
alter table profiles enable row level security;
alter table questions enable row level security;
alter table attempts enable row level security;
alter table attempt_answers enable row level security;
alter table wrong_book enable row level security;

create function is_supervisor() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'supervisor' from profiles where id = auth.uid()), false)
$$;

create policy profiles_select on profiles for select
  using (id = auth.uid() or is_supervisor());
create policy attempts_select on attempts for select
  using (user_id = auth.uid() or is_supervisor());
create policy attempt_answers_select on attempt_answers for select
  using (attempt_id in (select id from attempts));
create policy wrong_book_select on wrong_book for select
  using (user_id = auth.uid() or is_supervisor());
-- questions：刻意不建任何 policy，員工與主管都不能直接 select。

create view v_stage_summary with (security_invoker = true) as
select a.user_id, p.name, a.stage,
       max(a.score) as best_score,
       count(*)::int as attempts,
       coalesce(bool_or(a.passed), false) as passed
from attempts a join profiles p on p.id = a.user_id
where a.status = 'done'
group by a.user_id, p.name, a.stage;

create view v_error_counts with (security_invoker = true) as
select aa.error_type, a.user_id, count(*)::int as cnt
from attempt_answers aa join attempts a on a.id = aa.attempt_id
where aa.error_type is not null
group by aa.error_type, a.user_id;

-- 用戶端權限：預設全收回，只開放 select（匿名什麼都不給）。
revoke all on all tables in schema public from anon, authenticated;
grant select on profiles, attempts, attempt_answers, wrong_book, v_stage_summary, v_error_counts to authenticated;
revoke execute on function handle_new_user() from public, anon, authenticated;
grant execute on function is_supervisor() to authenticated;
