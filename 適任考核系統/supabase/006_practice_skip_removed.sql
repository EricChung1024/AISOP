-- 錯題區重練：已被主管刪除的題目不再出現（其餘邏輯與 004 相同）。
create or replace function start_practice(p_limit int default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); q questions; perm int[]; v_qids jsonb := '[]'::jsonb; v_client jsonb := '[]'::jsonb; v_run uuid;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  for q in select qs.* from questions qs join wrong_book w on w.question_id = qs.id
            where w.user_id = v_uid and w.status = 'open' and qs.qtype <> 'short' and not qs.removed
            order by random() limit greatest(coalesce(p_limit, 10), 1) loop
    perm := case when q.qtype = 'mcq' and q.shuffle
                 then array(select g - 1 from generate_series(1, jsonb_array_length(q.options)) g order by random())
                 else array(select g - 1 from generate_series(1, jsonb_array_length(q.options)) g order by g) end;
    v_qids := v_qids || jsonb_build_object('id', q.id, 'perm', to_jsonb(perm));
    v_client := v_client || jsonb_build_object('id', q.id, 'qtype', q.qtype, 'stem', q.stem,
      'options', (select jsonb_agg(q.options -> p order by ord) from unnest(perm) with ordinality u(p, ord)));
  end loop;
  if jsonb_array_length(v_qids) = 0 then raise exception 'NO_WRONG'; end if;
  insert into practice_runs (user_id, question_ids) values (v_uid, v_qids) returning id into v_run;
  return jsonb_build_object('practice_id', v_run, 'questions', v_client);
end $$;
