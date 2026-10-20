-- =====================================================================
-- Migration 51: ฟาร์ม — ปรับสมดุลเหรียญ/เลเวล (ข้อ ก + ข + ค ที่ผู้ใช้อนุมัติ 20 ต.ค. 2026)
--  ก) เลเวล 10 ขึ้นไปต้องใช้ XP เพิ่มขึ้นเท่าตัว
--     สูตรเดิม  XP ขั้นต่ำของเลเวล L = 5·L·(L−1)
--     สูตรใหม่ (L ≥ 10)          = 10·L·(L−1) − 450   (เลเวล 1–10 เหมือนเดิม)
--     คนที่ XP ≥ 450 ปรับ XP = 2·XP − 450 → เลเวลเดิมไม่ลด และความคืบหน้าในเลเวลยังเท่าเดิม
--  ข) ส่งคำสั่งซื้อได้ไม่เกิน 8 ใบ/คน/วัน (เวลาไทย) และรางวัลเหรียญ/XP ของใบสั่งลดลง 30%
--  ค) โบนัส XP เมื่อลงยอด KPI: ถึงเป้า +15 XP · ถึง 90% +8 XP (วันละครั้ง ให้อัตโนมัติ)
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================

-- ---------- ก) เลเวล ----------
-- ปรับ XP ก่อนเปลี่ยนสูตร (ทำครั้งเดียว: บันทึกไว้ในตาราง farm_meta กันรันซ้ำ)
create table if not exists public.farm_meta (k text primary key, v text, at timestamptz not null default now());
alter table public.farm_meta enable row level security;
revoke all on public.farm_meta from anon, authenticated, public;
do $$ begin
  if not exists (select 1 from public.farm_meta where k = 'xp_curve_v2') then
    update public.farm_profile set xp = 2 * xp - 450 where xp >= 450;
    insert into public.farm_meta (k, v) values ('xp_curve_v2', 'xp = 2*xp - 450 for xp >= 450');
  end if;
end $$;

create or replace function public.farm_level(p_xp int) returns int language sql immutable as $$
  select case when greatest(p_xp, 0) < 450
              then greatest(1, floor((1 + sqrt(1 + 4 * greatest(p_xp, 0) / 5.0)) / 2)::int)
              else floor((1 + sqrt(1 + 0.4 * (p_xp + 450))) / 2)::int end
$$;

-- ---------- ข) คำสั่งซื้อ ----------
create or replace function public.farm_orders_today(p_emp uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from farm_ledger
   where employee_id = p_emp and reason = 'ส่งคำสั่งซื้อ'
     and created_at >= ((now() at time zone 'Asia/Bangkok')::date)::timestamp at time zone 'Asia/Bangkok'
$$;

create or replace function public.farm_order_make(p_emp uuid, p_slot int, p_wait interval) returns void
language plpgsql security definer set search_path = public as $$
declare cat jsonb := public.farm_cat(); lv int; pool text[]; pick text[]; k text; q int; items jsonb := '{}'; val int := 0; n int; sell int;
begin
  select public.farm_level(xp) into lv from farm_profile where employee_id = p_emp;
  select array_agg(key) into pool from (
    select key from jsonb_each(cat->'crops') where (value->>'lv')::int <= lv
    union select distinct cat->'animals'->a.animal->>'prod' from farm_animals a where a.employee_id = p_emp
    union select distinct cat->'decor'->x.item->>'fruit' from farm_decor x where x.employee_id = p_emp and cat->'decor'->x.item ? 'fruit'
    union select jsonb_object_keys(cat->'machines'->m.machine->'recipes') from farm_machines m where m.employee_id = p_emp) z;
  n := 1 + floor(random() * least(3, 1 + lv / 2))::int;
  select array_agg(x) into pick from (select x from unnest(pool) x order by random() limit n) y;
  foreach k in array pick loop
    sell := coalesce((cat->'crops'->k->>'sell')::int, (cat->'products'->k->>'sell')::int, 5);
    q := case when cat->'crops' ? k then 2 + floor(random() * least(6, 2 + lv))::int else 1 + floor(random() * 3)::int end;
    items := items || jsonb_build_object(k, q);
    val := val + q * sell;
  end loop;
  -- เดิม: เหรียญ ×1.5 · XP val/6+1  →  ใหม่ (−30%): เหรียญ ×1.05 · XP val/8.5+1
  insert into farm_orders (employee_id, slot, items, coins, xp, ready_at)
  values (p_emp, p_slot, items, ceil(val * 1.05)::int, ceil(val / 8.5)::int + 1, now() + p_wait)
  on conflict (employee_id, slot) do update set items = excluded.items, coins = excluded.coins, xp = excluded.xp, ready_at = excluded.ready_at;
end $$;

-- ใบสั่งที่ค้างอยู่ลดรางวัลตาม (ครั้งเดียว)
do $$ begin
  if not exists (select 1 from public.farm_meta where k = 'orders_cut30') then
    update public.farm_orders set coins = ceil(coins * 0.7)::int, xp = greatest(1, ceil(xp * 0.7)::int);
    insert into public.farm_meta (k, v) values ('orders_cut30', 'coins/xp x0.7');
  end if;
end $$;

create or replace function public.farm_order_deliver(p_slot int) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); o farm_orders; k text; need int; have int; mx int := coalesce((public.farm_cat()->>'orders_per_day')::int, 8);
begin
  if public.farm_orders_today(e) >= mx then raise exception 'วันนี้ส่งคำสั่งซื้อครบ % ใบแล้ว พรุ่งนี้มาส่งใหม่นะ', mx; end if;
  select * into o from farm_orders where employee_id = e and slot = p_slot for update;
  if not found then raise exception 'ไม่พบคำสั่งซื้อ'; end if;
  if o.ready_at > now() then raise exception 'รถยังมาไม่ถึง'; end if;
  for k, need in select key, value::int from jsonb_each_text(o.items) loop
    select qty into have from farm_items where employee_id = e and item = k for update;
    if coalesce(have, 0) < need then raise exception 'ของไม่ครบ'; end if;
  end loop;
  for k, need in select key, value::int from jsonb_each_text(o.items) loop
    update farm_items set qty = qty - need where employee_id = e and item = k;
  end loop;
  insert into farm_ledger (employee_id, delta, reason) values (e, o.coins, 'ส่งคำสั่งซื้อ');
  perform public.farm_add_xp(e, o.xp);
  perform public.farm_order_make(e, p_slot, interval '3 minutes');
  return o.coins;
end $$;

create or replace function public.farm_orders() returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); lv int; n int; s int;
begin
  select public.farm_level(xp) into lv from farm_profile where employee_id = e;
  n := least(6, 2 + coalesce(lv, 1));
  for s in 1..n loop
    if not exists (select 1 from farm_orders where employee_id = e and slot = s) then perform public.farm_order_make(e, s, interval '0'); end if;
  end loop;
  return jsonb_build_object('now', now(), 'cap', public.farm_barn_cap(e), 'used', public.farm_barn_used(e),
    'barn_lv', (select barn_lv from farm_profile where employee_id = e),
    'done_today', public.farm_orders_today(e), 'max_day', coalesce((public.farm_cat()->>'orders_per_day')::int, 8),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('slot', slot, 'items', items, 'coins', coins, 'xp', xp, 'ready_at', ready_at) order by slot)
                          from farm_orders where employee_id = e and slot <= n), '[]'));
end $$;

do $do$ declare c jsonb := public.farm_cat(); begin
  c := c || '{"orders_per_day":8,"kpi_xp":{"hit":15,"near":8}}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

-- ---------- ค) โบนัส XP จาก KPI ----------
create table if not exists public.farm_kpi_xp (
  employee_id uuid not null references public.employees(id) on delete cascade,
  work_date   date not null,
  xp          int  not null default 0,
  primary key (employee_id, work_date)
);
alter table public.farm_kpi_xp enable row level security;
revoke all on public.farm_kpi_xp from anon, authenticated, public;

create or replace function public.farm_kpi_xp_of(p_output numeric, p_target numeric) returns int language sql immutable as $$
  select case when coalesce(p_target, 0) <= 0 then 0
              when p_output >= p_target then 15
              when p_output >= p_target * 0.9 then 8
              else 0 end
$$;

create or replace function public.farm_kpi_xp_grant(p_emp uuid, p_date date, p_xp int) returns void
language plpgsql security definer set search_path = public as $$
declare old int;
begin
  if p_xp <= 0 or not exists (select 1 from farm_profile where employee_id = p_emp) then return; end if;
  select xp into old from farm_kpi_xp where employee_id = p_emp and work_date = p_date for update;
  if old is null then
    insert into farm_kpi_xp (employee_id, work_date, xp) values (p_emp, p_date, p_xp);
    perform public.farm_add_xp(p_emp, p_xp);
  elsif p_xp > old then
    update farm_kpi_xp set xp = p_xp where employee_id = p_emp and work_date = p_date;
    perform public.farm_add_xp(p_emp, p_xp - old);
  end if;
end $$;

create or replace function public.farm_kpi_xp_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'rejected'
     and new.work_date >= (now() at time zone 'Asia/Bangkok')::date - 7
     and new.work_date >= coalesce((public.farm_cat()->>'kpi_from')::date, '2000-01-01') then
    perform public.farm_kpi_xp_grant(new.employee_id, new.work_date, public.farm_kpi_xp_of(new.output, new.target));
  end if;
  return null;
end $$;
drop trigger if exists work_logs_farm_kpi_xp on public.work_logs;
create trigger work_logs_farm_kpi_xp after insert or update of output, target, status on public.work_logs
  for each row execute function public.farm_kpi_xp_trg();

-- ให้ย้อนหลังสำหรับวันที่ผ่านมาตั้งแต่เปิดฟาร์ม (ครั้งเดียว)
do $$ declare r record; begin
  if not exists (select 1 from public.farm_meta where k = 'kpi_xp_backfill') then
    for r in select w.employee_id, w.work_date, max(public.farm_kpi_xp_of(w.output, w.target)) x
               from public.work_logs w
              where w.status <> 'rejected'
                and w.work_date >= coalesce((public.farm_cat()->>'kpi_from')::date, '2000-01-01')
              group by 1, 2 loop
      perform public.farm_kpi_xp_grant(r.employee_id, r.work_date, r.x);
    end loop;
    insert into public.farm_meta (k, v) values ('kpi_xp_backfill', 'done');
  end if;
end $$;

revoke execute on function public.farm_orders_today(uuid), public.farm_order_make(uuid, int, interval),
  public.farm_kpi_xp_grant(uuid, date, int), public.farm_kpi_xp_trg() from public, anon, authenticated;
revoke execute on function public.farm_order_deliver(int), public.farm_orders() from public, anon;
grant execute on function public.farm_order_deliver(int), public.farm_orders(), public.farm_kpi_xp_of(numeric, numeric) to authenticated;
notify pgrst, 'reload schema';
