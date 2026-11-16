-- 適任考核系統：資料表與觸發器
create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null,
  role text not null default 'employee' check (role in ('employee', 'supervisor'))
);

create table questions (
  id text primary key,
  stage int not null check (stage between 1 and 9),
  qtype text not null check (qtype in ('mcq', 'tf', 'short')),
  stem text not null,
  options jsonb,
  correct_index int,
  explanation text not null default '',
  error_type text,
  error_detail text,
  option_errors jsonb,
  reference_answer text,
  rubric jsonb,
  key_error text,
  source text not null default 'rules',
  source_ref text,
  reviewed boolean not null default false,
  red_line boolean not null default false
);

create table attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  stage int not null check (stage between 0 and 9),
  question_ids jsonb not null default '[]'::jsonb,
  status text not null default 'in_progress' check (status in ('in_progress', 'pending_selfcheck', 'done')),
  score numeric,
  passed boolean,
  started_at timestamptz not null default now(),
  submitted_at timestamptz
);
create index attempts_user_idx on attempts (user_id);

create table attempt_answers (
  attempt_id uuid not null references attempts (id) on delete cascade,
  question_id text not null references questions (id),
  choice int,
  text_answer text,
  checked jsonb,
  points numeric,
  is_correct boolean,
  error_type text,
  error_detail text,
  primary key (attempt_id, question_id)
);

create table wrong_book (
  user_id uuid not null references profiles (id) on delete cascade,
  question_id text not null references questions (id),
  wrong_count int not null default 1,
  streak int not null default 0,
  status text not null default 'open' check (status in ('open', 'mastered')),
  note text,
  last_wrong_at timestamptz not null default now(),
  primary key (user_id, question_id)
);

-- 新的 auth 使用者自動建立 employee profile
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name, role)
  values (new.id,
          coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(new.email, '@', 1)),
          'employee');
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
for each row execute function handle_new_user();
