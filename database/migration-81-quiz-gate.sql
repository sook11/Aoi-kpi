-- =====================================================================
-- อัปเดต 163: H.P.E Champion — บังคับตอบวันละ 5 ข้อ (พนักงาน) + เวลาไม่จำกัด (Admin ตั้งได้) + สถิติของฉัน
--   * ตอบผิดไม่จบเกมแล้ว — ต้องตอบให้ครบ 5 ข้อ (ได้เหรียญเฉพาะข้อที่ถูก · ถูกครบ 5 = โบนัส)
--   * secs = 0 → ไม่จำกัดเวลา (ค่าเริ่มต้น) · Admin ตั้งได้ใน quiz_cfg_set
--   * gate = true → พนักงาน (role='employee') ต้องตอบเมื่อเปิดแอป · หัวหน้างานไม่บังคับ
-- =====================================================================
create or replace function public.quiz_cfg() returns jsonb
language sql stable security definer set search_path = public as $$
  select '{"ladder":[20,40,60,80,100],"bonus":100,"secs":0,"grace":15,"per_day":5,"gate":true}'::jsonb || coalesce((select value from app_settings where key = 'quiz_cfg'), '{}'::jsonb)
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
  if p ? 'gate' then cur := cur || jsonb_build_object('gate', (p->>'gate')::boolean); end if;
  insert into app_settings (key, value) values ('quiz_cfg', cur) on conflict (key) do update set value = excluded.value;
  return public.quiz_cfg();
end $$;

create or replace function public.quiz_state(p_emp uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g quiz_days; q quiz_questions; c jsonb := public.quiz_cfg(); left_s numeric; ch jsonb; lim numeric := coalesce((c->>'secs')::numeric, 0);
begin
  select * into g from quiz_days where employee_id = p_emp and day = public.quiz_today_date();
  if not found then return jsonb_build_object('cfg', c, 'bank', (select count(*) from quiz_questions where active)); end if;
  if g.status = 'playing' and g.step < array_length(g.qids, 1) then
    select * into q from quiz_questions where id = g.qids[g.step + 1];
    ch := (select jsonb_agg(case when i - 1 = any(g.hide) then null else q.choices->(i - 1) end order by i) from generate_series(1, 4) i);
    if lim > 0 then left_s := greatest(0, lim - extract(epoch from (now() - g.cur_at))); end if;
  end if;
  return jsonb_build_object('cfg', c, 'day', g.day, 'step', g.step, 'total', array_length(g.qids, 1), 'status', g.status, 'coins', g.coins,
    'lifelines', g.lifelines, 'q', case when q.id is null then null else jsonb_build_object('id', q.id, 'text', q.question, 'ref', q.ref, 'choices', ch) end,
    'left', left_s,
    'res', (select coalesce(jsonb_agg(a.correct order by a.idx), '[]') from quiz_answers a where a.employee_id = p_emp and a.day = g.day),
    'log', (select coalesce(jsonb_agg(jsonb_build_object('idx', a.idx, 'correct', a.correct, 'choice', a.choice, 'answer', qq.answer, 'text', qq.question, 'choices', qq.choices, 'ref', qq.ref) order by a.idx), '[]')
              from quiz_answers a join quiz_questions qq on qq.id = a.qid where a.employee_id = p_emp and a.day = g.day and g.status <> 'playing'));
end $$;

create or replace function public.quiz_answer(p_choice int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); g quiz_days; q quiz_questions; c jsonb := public.quiz_cfg(); ok boolean; secs numeric; win int := 0; bonus int := 0; late boolean;
        lim numeric := coalesce((c->>'secs')::numeric, 0); last boolean; nright int;
begin
  select * into g from quiz_days where employee_id = me and day = public.quiz_today_date() for update;
  if not found or g.status <> 'playing' then raise exception 'ตอบครบแล้ววันนี้ — มาเล่นใหม่พรุ่งนี้'; end if;
  select * into q from quiz_questions where id = g.qids[g.step + 1];
  secs := extract(epoch from (now() - g.cur_at));
  late := p_choice is null or (lim > 0 and secs > lim + coalesce((c->>'grace')::numeric, 15));
  ok := not late and p_choice = q.answer;
  last := g.step + 1 >= array_length(g.qids, 1);
  insert into quiz_answers (employee_id, day, idx, qid, choice, correct, secs) values (me, g.day, g.step + 1, q.id, case when late then null else p_choice end, ok, round(secs, 1));
  nright := (select count(*) from quiz_answers where employee_id = me and day = g.day and correct);
  if ok then
    win := coalesce((c->'ladder'->>g.step)::int, 0);
    if last and nright >= array_length(g.qids, 1) then bonus := coalesce((c->>'bonus')::int, 0); end if;
  end if;
  update quiz_days set step = step + 1, coins = coins + win + bonus, hide = '{}', cur_at = now(),
         status = case when not last then 'playing' when nright >= array_length(g.qids, 1) then 'done' else 'lost' end,
         ended_at = case when last then now() end
   where employee_id = me and day = g.day;
  if win + bonus > 0 then
    insert into farm_ledger (employee_id, delta, reason) values (me, win + bonus, 'เกม H.P.E Champion ข้อ ' || (g.step + 1) || case when bonus > 0 then ' + โบนัสถูกครบ 5 ข้อ' else '' end);
  end if;
  return jsonb_build_object('correct', ok, 'late', late, 'answer', q.answer, 'win', win, 'bonus', bonus, 'ref', q.ref, 'last', last) || jsonb_build_object('state', public.quiz_state(me));
end $$;

-- สถิติของฉัน (หน้าภาพรวม): ตอบไปกี่ข้อ ถูก/ผิด และอันดับในช่วงวันที่
create or replace function public.quiz_me(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); r jsonb;
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  with t as (
    select d.employee_id id, coalesce(sum(d.coins), 0)::int coins,
           (select count(*) from quiz_answers a where a.employee_id = d.employee_id and a.day between p_from and p_to and a.correct)::int correct,
           (select count(*) from quiz_answers a where a.employee_id = d.employee_id and a.day between p_from and p_to and not a.correct)::int wrong
      from quiz_days d join employees e on e.id = d.employee_id and e.active
     where d.day between p_from and p_to group by d.employee_id),
  k as (select t.*, rank() over (order by coins desc, correct desc, wrong) rk, count(*) over () n from t)
  select jsonb_build_object('answered', coalesce(k.correct + k.wrong, 0), 'correct', coalesce(k.correct, 0), 'wrong', coalesce(k.wrong, 0),
                            'coins', coalesce(k.coins, 0), 'rank', k.rk, 'players', (select count(*) from t))
    into r from (select 1) one left join k on k.id = me;
  return r || jsonb_build_object('today', public.quiz_state(me), 'role', (select role from employees where id = me));
end $$;

-- ตัวช่วยเหลือแค่ "เปลี่ยนข้อ" (ตัด 50:50 / ถามผู้ชม / โทรหาเพื่อน — ไม่ใช่รายการทีวี)
create or replace function public.quiz_lifeline(p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); g quiz_days; nid bigint[];
begin
  select * into g from quiz_days where employee_id = me and day = public.quiz_today_date() for update;
  if not found or g.status <> 'playing' then raise exception 'เกมวันนี้จบแล้ว'; end if;
  if p_kind <> 'swap' then raise exception 'ตัวช่วยนี้ปิดใช้งานแล้ว'; end if;
  if g.lifelines ? p_kind then raise exception 'ใช้ตัวช่วยนี้ไปแล้ววันนี้'; end if;
  nid := public.quiz_pick(me, 1, g.qids);
  if coalesce(array_length(nid, 1), 0) = 0 then raise exception 'ไม่มีคำถามสำรองให้เปลี่ยน'; end if;
  update quiz_days set qids[g.step + 1] = nid[1], hide = '{}', cur_at = now(), lifelines = lifelines || jsonb_build_object(p_kind, '{}'::jsonb) where employee_id = me and day = g.day;
  return jsonb_build_object('state', public.quiz_state(me));
end $$;

revoke execute on function public.quiz_cfg_set(jsonb), public.quiz_me(date, date) from public, anon;
grant execute on function public.quiz_cfg_set(jsonb), public.quiz_me(date, date) to authenticated;
notify pgrst, 'reload schema';
