-- =====================================================================
-- อัปเดต 164: H.P.E Champion — เล่นได้ไม่จำกัดรอบ (ผ่านฟาร์ม/เมนู) + บังคับเฉพาะรอบแรกของวัน
--   round 0  = รอบประจำวัน (บังคับพนักงานตอนเปิดแอป วันละครั้ง)
--   round 1+ = รอบเล่นเพิ่ม ไม่จำกัดรอบ · เหรียญรอบเล่นเพิ่มรวมกันต่อวันไม่เกิน free_cap (Admin ตั้งได้)
-- =====================================================================
alter table public.quiz_days add column if not exists round int not null default 0;
alter table public.quiz_answers add column if not exists round int not null default 0;
alter table public.quiz_days drop constraint if exists quiz_days_pkey;
alter table public.quiz_days add primary key (employee_id, day, round);

create or replace function public.quiz_cfg() returns jsonb
language sql stable security definer set search_path = public as $$
  select '{"ladder":[20,40,60,80,100],"bonus":100,"secs":0,"grace":15,"per_day":5,"gate":true,"free_on":true,"free_cap":300}'::jsonb || coalesce((select value from app_settings where key = 'quiz_cfg'), '{}'::jsonb)
$$;

create or replace function public.quiz_cfg_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cur jsonb := coalesce((select value from app_settings where key = 'quiz_cfg'), '{}'::jsonb); s int;
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  if p ? 'secs' then
    s := (p->>'secs')::int;
    if s < 0 or s > 600 then raise exception 'เวลาต่อข้อ 0–600 วินาที (0 = ไม่จำกัด)'; end if;
    cur := cur || jsonb_build_object('secs', s);
  end if;
  if p ? 'free_cap' then
    s := (p->>'free_cap')::int;
    if s < 0 or s > 100000 then raise exception 'เพดานเหรียญรอบเล่นเพิ่ม 0–100000'; end if;
    cur := cur || jsonb_build_object('free_cap', s);
  end if;
  if p ? 'gate' then cur := cur || jsonb_build_object('gate', (p->>'gate')::boolean); end if;
  if p ? 'free_on' then cur := cur || jsonb_build_object('free_on', (p->>'free_on')::boolean); end if;
  insert into app_settings (key, value) values ('quiz_cfg', cur) on conflict (key) do update set value = excluded.value;
  return public.quiz_cfg();
end $$;

-- เกมล่าสุดของวันนี้ (รอบมากสุด)
create or replace function public.quiz_cur(p_emp uuid) returns public.quiz_days
language sql stable security definer set search_path = public as $$
  select * from quiz_days where employee_id = p_emp and day = public.quiz_today_date() order by round desc limit 1
$$;

create or replace function public.quiz_state(p_emp uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g quiz_days; q quiz_questions; c jsonb := public.quiz_cfg(); left_s numeric; ch jsonb; lim numeric := coalesce((c->>'secs')::numeric, 0);
        dd boolean; got int;
begin
  dd := exists (select 1 from quiz_days where employee_id = p_emp and day = public.quiz_today_date() and round = 0 and status <> 'playing');
  got := (select coalesce(sum(coins), 0) from quiz_days where employee_id = p_emp and day = public.quiz_today_date() and round > 0);
  select * into g from quiz_days where employee_id = p_emp and day = public.quiz_today_date() order by round desc limit 1;
  if not found then return jsonb_build_object('cfg', c, 'bank', (select count(*) from quiz_questions where active), 'daily_done', false, 'free_got', 0); end if;
  if g.status = 'playing' and g.step < array_length(g.qids, 1) then
    select * into q from quiz_questions where id = g.qids[g.step + 1];
    ch := (select jsonb_agg(case when i - 1 = any(g.hide) then null else q.choices->(i - 1) end order by i) from generate_series(1, 4) i);
    if lim > 0 then left_s := greatest(0, lim - extract(epoch from (now() - g.cur_at))); end if;
  end if;
  return jsonb_build_object('cfg', c, 'day', g.day, 'round', g.round, 'daily_done', dd, 'free_got', got,
    'bank', (select count(*) from quiz_questions where active),
    'step', g.step, 'total', array_length(g.qids, 1), 'status', g.status, 'coins', g.coins,
    'lifelines', g.lifelines, 'q', case when q.id is null then null else jsonb_build_object('id', q.id, 'text', q.question, 'ref', q.ref, 'choices', ch) end,
    'left', left_s,
    'res', (select coalesce(jsonb_agg(a.correct order by a.idx), '[]') from quiz_answers a where a.employee_id = p_emp and a.day = g.day and a.round = g.round),
    'log', (select coalesce(jsonb_agg(jsonb_build_object('idx', a.idx, 'correct', a.correct, 'choice', a.choice, 'answer', qq.answer, 'text', qq.question, 'choices', qq.choices, 'ref', qq.ref) order by a.idx), '[]')
              from quiz_answers a join quiz_questions qq on qq.id = a.qid where a.employee_id = p_emp and a.day = g.day and a.round = g.round and g.status <> 'playing'));
end $$;

drop function if exists public.quiz_start();
create or replace function public.quiz_start(p_again boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); ids bigint[]; c jsonb := public.quiz_cfg(); n int := (c->>'per_day')::int; g quiz_days; nr int := 0;
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  select * into g from quiz_days where employee_id = me and day = public.quiz_today_date() order by round desc limit 1;
  if found then
    if g.status = 'playing' or not coalesce(p_again, false) then return public.quiz_state(me); end if;
    if not coalesce((c->>'free_on')::boolean, true) then raise exception 'Admin ปิดรอบเล่นเพิ่มไว้ — มาเล่นใหม่พรุ่งนี้'; end if;
    nr := g.round + 1;
  end if;
  ids := public.quiz_pick(me, n);
  if coalesce(array_length(ids, 1), 0) < n then raise exception 'คลังคำถามยังไม่พอ — ให้ Admin นำเข้าคำถามก่อน'; end if;
  insert into quiz_days (employee_id, day, round, qids, cur_at) values (me, public.quiz_today_date(), nr, ids, now()) on conflict do nothing;
  return public.quiz_state(me);
end $$;

create or replace function public.quiz_answer(p_choice int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); g quiz_days; q quiz_questions; c jsonb := public.quiz_cfg(); ok boolean; secs numeric; win int := 0; bonus int := 0; late boolean;
        lim numeric := coalesce((c->>'secs')::numeric, 0); last boolean; nright int; room int; capped boolean := false;
begin
  select * into g from quiz_days where employee_id = me and day = public.quiz_today_date() order by round desc limit 1 for update;
  if not found or g.status <> 'playing' then raise exception 'รอบนี้ตอบครบแล้ว — กด "เล่นอีกรอบ" เพื่อเล่นต่อ'; end if;
  select * into q from quiz_questions where id = g.qids[g.step + 1];
  secs := extract(epoch from (now() - g.cur_at));
  late := p_choice is null or (lim > 0 and secs > lim + coalesce((c->>'grace')::numeric, 15));
  ok := not late and p_choice = q.answer;
  last := g.step + 1 >= array_length(g.qids, 1);
  insert into quiz_answers (employee_id, day, round, idx, qid, choice, correct, secs) values (me, g.day, g.round, g.step + 1, q.id, case when late then null else p_choice end, ok, round(secs, 1));
  nright := (select count(*) from quiz_answers where employee_id = me and day = g.day and round = g.round and correct);
  if ok then
    win := coalesce((c->'ladder'->>g.step)::int, 0);
    if last and nright >= array_length(g.qids, 1) then bonus := coalesce((c->>'bonus')::int, 0); end if;
    if g.round > 0 then
      room := greatest(0, coalesce((c->>'free_cap')::int, 300) - (select coalesce(sum(coins), 0) from quiz_days where employee_id = me and day = g.day and round > 0));
      capped := win + bonus > room;
      win := least(win, room); bonus := least(bonus, room - win);
    end if;
  end if;
  update quiz_days set step = step + 1, coins = coins + win + bonus, hide = '{}', cur_at = now(),
         status = case when not last then 'playing' when nright >= array_length(g.qids, 1) then 'done' else 'lost' end,
         ended_at = case when last then now() end
   where employee_id = me and day = g.day and round = g.round;
  if win + bonus > 0 then
    insert into farm_ledger (employee_id, delta, reason) values (me, win + bonus, 'เกม H.P.E Champion ' || case when g.round = 0 then 'ประจำวัน' else 'รอบเล่นเพิ่ม' end || ' ข้อ ' || (g.step + 1) || case when bonus > 0 then ' + โบนัสถูกครบ 5 ข้อ' else '' end);
  end if;
  return jsonb_build_object('correct', ok, 'late', late, 'answer', q.answer, 'win', win, 'bonus', bonus, 'capped', capped, 'ref', q.ref, 'last', last) || jsonb_build_object('state', public.quiz_state(me));
end $$;

create or replace function public.quiz_lifeline(p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); g quiz_days; nid bigint[];
begin
  select * into g from quiz_days where employee_id = me and day = public.quiz_today_date() order by round desc limit 1 for update;
  if not found or g.status <> 'playing' then raise exception 'รอบนี้จบแล้ว'; end if;
  if p_kind <> 'swap' then raise exception 'ตัวช่วยนี้ปิดใช้งานแล้ว'; end if;
  if g.lifelines ? p_kind then raise exception 'ใช้ตัวช่วยนี้ไปแล้วในรอบนี้'; end if;
  nid := public.quiz_pick(me, 1, g.qids);
  if coalesce(array_length(nid, 1), 0) = 0 then raise exception 'ไม่มีคำถามสำรองให้เปลี่ยน'; end if;
  update quiz_days set qids[g.step + 1] = nid[1], hide = '{}', cur_at = now(), lifelines = lifelines || jsonb_build_object(p_kind, '{}'::jsonb)
   where employee_id = me and day = g.day and round = g.round;
  return jsonb_build_object('state', public.quiz_state(me));
end $$;

-- สถิติ: นับเฉพาะคนที่ active · "วันที่เล่น" นับวันไม่ซ้ำ · รวมทุกรอบ
create or replace function public.quiz_stats(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.my_employee_id();
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(z order by z.coins desc, z.correct desc, z.wrong) from (
      select e.id, e.employee_no no, coalesce(nullif(e.display_name, ''), e.employee_no) name, e.department_id dept_id,
             count(distinct d.day)::int days, count(*)::int rounds, coalesce(sum(d.coins), 0)::int coins,
             (select count(*) from quiz_answers a where a.employee_id = e.id and a.day between p_from and p_to and a.correct)::int correct,
             (select count(*) from quiz_answers a where a.employee_id = e.id and a.day between p_from and p_to and not a.correct)::int wrong,
             count(*) filter (where d.status = 'done')::int perfect
        from employees e join quiz_days d on d.employee_id = e.id and d.day between p_from and p_to
       where e.active group by e.id) z), '[]'::jsonb),
    'absent', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'no', e.employee_no, 'name', coalesce(nullif(e.display_name, ''), e.employee_no), 'dept_id', e.department_id) order by e.employee_no)
       from employees e where e.active and e.role = 'employee' and not exists (select 1 from quiz_days d where d.employee_id = e.id and d.day between p_from and p_to)), '[]'::jsonb),
    'bank', (select count(*) from quiz_questions where active),
    'played_today', (select count(distinct employee_id) from quiz_days where day = public.quiz_today_date()));
end $$;

revoke execute on function public.quiz_cur(uuid) from public, anon, authenticated;
revoke execute on function public.quiz_start(boolean) from public, anon;
grant execute on function public.quiz_start(boolean) to authenticated;
notify pgrst, 'reload schema';
