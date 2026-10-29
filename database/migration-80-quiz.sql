-- =====================================================================
-- อัปเดต 162: เกม H.P.E Champion (แนวเกมเศรษฐี) — ตอบคำถามจากคู่มือการทำงาน วันละ 5 ข้อ สะสมเหรียญฟาร์ม
--   quiz_questions : คลังคำถาม (นำเข้าจาก Google Sheet / Excel) · คำตอบที่ถูกเก็บฝั่งเซิร์ฟเวอร์ ไม่ส่งให้เครื่องผู้เล่นก่อนตอบ
--   quiz_days      : เกมของแต่ละคนต่อวัน (สุ่ม 5 ข้อใหม่ทุกวัน)
--   quiz_answers   : ประวัติคำตอบ (ใช้ทำสถิติ)
--   ตอบถูก = ได้เหรียญตามขั้นบันได · ตอบผิด/หมดเวลา = จบเกมวันนั้น (เหรียญที่ได้แล้วยังอยู่) · ครบ 5 ข้อ = โบนัส
--   ตัวช่วย วันละ 1 ครั้งต่อชนิด: 50:50 · ถามผู้ชม · โทรหาเพื่อน · เปลี่ยนคำถาม
-- =====================================================================
create table if not exists public.quiz_questions (
  id         bigserial primary key,
  sheet      text not null default '',
  no         int  not null default 0,
  question   text not null,
  ref        text not null default '',
  choices    jsonb not null,
  answer     int  not null check (answer between 0 and 3),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (sheet, no)
);
create table if not exists public.quiz_days (
  employee_id uuid not null references public.employees(id) on delete cascade,
  day         date not null,
  qids        bigint[] not null,
  step        int  not null default 0,
  status      text not null default 'playing' check (status in ('playing','done','lost','timeout')),
  coins       int  not null default 0,
  lifelines   jsonb not null default '{}'::jsonb,
  hide        int[] not null default '{}',
  cur_at      timestamptz,
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  primary key (employee_id, day)
);
create table if not exists public.quiz_answers (
  id          bigserial primary key,
  employee_id uuid not null references public.employees(id) on delete cascade,
  day         date not null,
  idx         int  not null,
  qid         bigint not null references public.quiz_questions(id) on delete cascade,
  choice      int,
  correct     boolean not null,
  secs        numeric,
  at          timestamptz not null default now()
);
create index if not exists quiz_answers_emp on public.quiz_answers (employee_id, day);
create index if not exists quiz_answers_day on public.quiz_answers (day);
alter table public.quiz_questions enable row level security;
alter table public.quiz_days enable row level security;
alter table public.quiz_answers enable row level security;
revoke all on public.quiz_questions, public.quiz_days, public.quiz_answers from anon, public, authenticated;

create or replace function public.quiz_cfg() returns jsonb
language sql stable security definer set search_path = public as $$
  select '{"ladder":[20,40,60,80,100],"bonus":100,"secs":30,"grace":15,"per_day":5}'::jsonb || coalesce((select value from app_settings where key = 'quiz_cfg'), '{}'::jsonb)
$$;
create or replace function public.quiz_today_date() returns date language sql stable as $$ select (now() at time zone 'Asia/Bangkok')::date $$;

-- สุ่มคำถามที่ยังไม่ได้เล่นใน 30 วันล่าสุด (ถ้าไม่พอ ให้สุ่มจากทั้งหมด)
create or replace function public.quiz_pick(p_emp uuid, p_n int, p_not bigint[] default '{}') returns bigint[]
language sql volatile security definer set search_path = public as $$
  select coalesce(array_agg(id), '{}') from (
    select q.id from quiz_questions q
     where q.active and not (q.id = any(p_not))
     order by (exists (select 1 from quiz_answers a where a.employee_id = p_emp and a.qid = q.id and a.day > public.quiz_today_date() - 30)), random()
     limit p_n) z
$$;

create or replace function public.quiz_state(p_emp uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g quiz_days; q quiz_questions; c jsonb := public.quiz_cfg(); left_s numeric; ch jsonb;
begin
  select * into g from quiz_days where employee_id = p_emp and day = public.quiz_today_date();
  if not found then return jsonb_build_object('cfg', c, 'bank', (select count(*) from quiz_questions where active)); end if;
  if g.status = 'playing' and g.step < array_length(g.qids, 1) then
    select * into q from quiz_questions where id = g.qids[g.step + 1];
    ch := (select jsonb_agg(case when i - 1 = any(g.hide) then null else q.choices->(i - 1) end order by i) from generate_series(1, 4) i);
    left_s := greatest(0, (c->>'secs')::numeric - extract(epoch from (now() - g.cur_at)));
  end if;
  return jsonb_build_object('cfg', c, 'day', g.day, 'step', g.step, 'total', array_length(g.qids, 1), 'status', g.status, 'coins', g.coins,
    'lifelines', g.lifelines, 'q', case when q.id is null then null else jsonb_build_object('id', q.id, 'text', q.question, 'ref', q.ref, 'choices', ch) end,
    'left', left_s,
    'log', (select coalesce(jsonb_agg(jsonb_build_object('idx', a.idx, 'correct', a.correct, 'choice', a.choice, 'answer', qq.answer, 'text', qq.question, 'choices', qq.choices, 'ref', qq.ref) order by a.idx), '[]')
              from quiz_answers a join quiz_questions qq on qq.id = a.qid where a.employee_id = p_emp and a.day = g.day and g.status <> 'playing'));
end $$;

create or replace function public.quiz_today() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); g quiz_days; ids bigint[]; n int;
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  return public.quiz_state(me);
end $$;

create or replace function public.quiz_start() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); ids bigint[]; n int := (public.quiz_cfg()->>'per_day')::int;
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  if exists (select 1 from quiz_days where employee_id = me and day = public.quiz_today_date()) then return public.quiz_state(me); end if;
  ids := public.quiz_pick(me, n);
  if coalesce(array_length(ids, 1), 0) < n then raise exception 'คลังคำถามยังไม่พอ — ให้ Admin นำเข้าคำถามก่อน'; end if;
  insert into quiz_days (employee_id, day, qids, cur_at) values (me, public.quiz_today_date(), ids, now()) on conflict do nothing;
  return public.quiz_state(me);
end $$;

create or replace function public.quiz_answer(p_choice int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); g quiz_days; q quiz_questions; c jsonb := public.quiz_cfg(); ok boolean; secs numeric; win int := 0; bonus int := 0; late boolean;
begin
  select * into g from quiz_days where employee_id = me and day = public.quiz_today_date() for update;
  if not found or g.status <> 'playing' then raise exception 'เกมวันนี้จบแล้ว — มาเล่นใหม่พรุ่งนี้'; end if;
  select * into q from quiz_questions where id = g.qids[g.step + 1];
  secs := extract(epoch from (now() - g.cur_at));
  late := p_choice is null or secs > (c->>'secs')::numeric + (c->>'grace')::numeric;
  ok := not late and p_choice is not null and p_choice = q.answer;
  insert into quiz_answers (employee_id, day, idx, qid, choice, correct, secs) values (me, g.day, g.step + 1, q.id, case when late then null else p_choice end, ok, round(secs, 1));
  if ok then
    win := (c->'ladder'->>g.step)::int;
    if g.step + 1 >= array_length(g.qids, 1) then bonus := coalesce((c->>'bonus')::int, 0); end if;
    update quiz_days set step = step + 1, coins = coins + win + bonus, hide = '{}', cur_at = now(),
      status = case when g.step + 1 >= array_length(g.qids, 1) then 'done' else 'playing' end,
      ended_at = case when g.step + 1 >= array_length(g.qids, 1) then now() end
     where employee_id = me and day = g.day;
    insert into farm_ledger (employee_id, delta, reason) values (me, win + bonus, 'เกม H.P.E Champion ข้อ ' || (g.step + 1) || case when bonus > 0 then ' + โบนัสครบ 5 ข้อ' else '' end);
  else
    update quiz_days set status = case when late then 'timeout' else 'lost' end, ended_at = now() where employee_id = me and day = g.day;
  end if;
  return jsonb_build_object('correct', ok, 'late', late, 'answer', q.answer, 'win', win, 'bonus', bonus, 'ref', q.ref) || jsonb_build_object('state', public.quiz_state(me));
end $$;

create or replace function public.quiz_lifeline(p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); g quiz_days; q quiz_questions; wrong int[]; r jsonb; pc int[]; k int; fr text; sure boolean; nid bigint[];
begin
  select * into g from quiz_days where employee_id = me and day = public.quiz_today_date() for update;
  if not found or g.status <> 'playing' then raise exception 'เกมวันนี้จบแล้ว'; end if;
  if p_kind not in ('fifty','aud','phone','swap') then raise exception 'ตัวช่วยไม่ถูกต้อง'; end if;
  if g.lifelines ? p_kind then raise exception 'ใช้ตัวช่วยนี้ไปแล้ววันนี้'; end if;
  select * into q from quiz_questions where id = g.qids[g.step + 1];
  wrong := array(select i from generate_series(0, 3) i where i <> q.answer and not (i = any(g.hide)) order by random());
  if p_kind = 'fifty' then
    update quiz_days set hide = hide || wrong[1:2] where employee_id = me and day = g.day;
    r := jsonb_build_object('hide', to_jsonb(g.hide || wrong[1:2]));
  elsif p_kind = 'aud' then
    k := 38 + floor(random() * 35)::int; pc := array[0,0,0,0]; pc[q.answer + 1] := k;
    for i in 1..array_length(wrong, 1) loop pc[wrong[i] + 1] := case when i = array_length(wrong, 1) then 100 - (select sum(x) from unnest(pc) x) else floor(random() * (100 - (select sum(x) from unnest(pc) x)) * 0.6)::int end; end loop;
    r := jsonb_build_object('aud', to_jsonb(pc));
  elsif p_kind = 'phone' then
    select coalesce(nullif(e.display_name, ''), e.employee_no) into fr from employees e where e.active and e.id <> me order by random() limit 1;
    sure := random() < 0.8;
    r := jsonb_build_object('friend', coalesce(fr, 'เพื่อนร่วมงาน'), 'pick', case when sure then q.answer else wrong[1] end, 'conf', case when sure then 60 + floor(random() * 35)::int else 35 + floor(random() * 25)::int end);
  else
    nid := public.quiz_pick(me, 1, g.qids);
    if coalesce(array_length(nid, 1), 0) = 0 then raise exception 'ไม่มีคำถามสำรองให้เปลี่ยน'; end if;
    update quiz_days set qids[g.step + 1] = nid[1], hide = '{}', cur_at = now() where employee_id = me and day = g.day;
    r := '{}'::jsonb;
  end if;
  update quiz_days set lifelines = lifelines || jsonb_build_object(p_kind, coalesce(r, '{}'::jsonb)) where employee_id = me and day = g.day;
  return r || jsonb_build_object('state', public.quiz_state(me));
end $$;

-- สถิติ: ใครตอบถูกเยอะ / ตอบผิด / ไม่เข้าเล่น (ช่วงวันที่)
create or replace function public.quiz_stats(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.my_employee_id();
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(z order by z.coins desc, z.correct desc, z.wrong) from (
      select e.id, e.employee_no no, coalesce(nullif(e.display_name, ''), e.employee_no) name, e.department_id dept_id,
             count(distinct d.day)::int days, coalesce(sum(d.coins), 0)::int coins,
             (select count(*) from quiz_answers a where a.employee_id = e.id and a.day between p_from and p_to and a.correct)::int correct,
             (select count(*) from quiz_answers a where a.employee_id = e.id and a.day between p_from and p_to and not a.correct)::int wrong,
             count(*) filter (where d.status = 'done')::int perfect
        from employees e join quiz_days d on d.employee_id = e.id and d.day between p_from and p_to
       where e.active group by e.id) z), '[]'::jsonb),
    'absent', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'no', e.employee_no, 'name', coalesce(nullif(e.display_name, ''), e.employee_no), 'dept_id', e.department_id) order by e.employee_no)
       from employees e where e.active and e.role = 'employee' and not exists (select 1 from quiz_days d where d.employee_id = e.id and d.day between p_from and p_to)), '[]'::jsonb),
    'bank', (select count(*) from quiz_questions where active),
    'played_today', (select count(*) from quiz_days where day = public.quiz_today_date()));
end $$;

-- Admin: นำเข้าคำถาม rows = [{sheet,no,question,ref,choices:[4],answer:0-3}]
create or replace function public.quiz_import(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; n int := 0; bad int := 0;
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    if coalesce(x->>'question', '') = '' or jsonb_array_length(coalesce(x->'choices', '[]')) <> 4 or (x->>'answer') is null or (x->>'answer')::int not between 0 and 3 then bad := bad + 1; continue; end if;
    insert into quiz_questions (sheet, no, question, ref, choices, answer, active)
    values (coalesce(x->>'sheet', ''), coalesce((x->>'no')::int, 0), x->>'question', coalesce(x->>'ref', ''), x->'choices', (x->>'answer')::int, true)
    on conflict (sheet, no) do update set question = excluded.question, ref = excluded.ref, choices = excluded.choices, answer = excluded.answer, active = true;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', n, 'bad', bad, 'bank', (select count(*) from quiz_questions where active));
end $$;
create or replace function public.quiz_bank() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('sheet', sheet, 'n', n, 'on', o) order by sheet) from (select sheet, count(*) n, count(*) filter (where active) o from quiz_questions group by sheet) z), '[]');
end $$;
create or replace function public.quiz_sheet_active(p_sheet text, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  update quiz_questions set active = p_on where sheet = p_sheet;
end $$;

revoke execute on function public.quiz_pick(uuid, int, bigint[]), public.quiz_state(uuid) from public, anon, authenticated;
revoke execute on function public.quiz_cfg(), public.quiz_today(), public.quiz_start(), public.quiz_answer(int), public.quiz_lifeline(text), public.quiz_stats(date, date), public.quiz_import(jsonb), public.quiz_bank(), public.quiz_sheet_active(text, boolean) from public, anon;
grant execute on function public.quiz_cfg(), public.quiz_today(), public.quiz_start(), public.quiz_answer(int), public.quiz_lifeline(text), public.quiz_stats(date, date), public.quiz_import(jsonb), public.quiz_bank(), public.quiz_sheet_active(text, boolean) to authenticated;
notify pgrst, 'reload schema';
