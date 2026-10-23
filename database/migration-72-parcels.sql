-- =====================================================================
-- Migration 72: ที่ดินขยาย 20 แปลง (ขนาดสุ่ม) — ยิ่งกว้างยิ่งแพง · ซื้อได้เฉพาะแปลงที่ติดกับพื้นที่บ้าน/แปลงที่ซื้อแล้ว
--   ใช้ทำอะไรก็ได้: 🌱 ปลูกผัก (ทุกช่องเป็นแปลงผัก) · 🐄 คอกสัตว์ (ทุก 2×2 ช่อง = 1 คอก) · 🌳 ลานของแต่ง
--   ราคา = กว้าง×ยาว × 160 × 1.12^(จำนวนแปลงที่ซื้อแล้ว) · ต้องเลเวล 5 ขึ้นไป
--   ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := c || jsonb_build_object('parcels', '[{"id": 0, "x": -3.2, "y": 15.2, "w": 3, "h": 3, "adj": [1, 4], "core": true}, {"id": 1, "x": 0.1, "y": 15.2, "w": 3, "h": 3, "adj": [0, 4, 5], "core": true}, {"id": 2, "x": 8.5, "y": 15.2, "w": 5, "h": 3, "adj": [3, 6, 7], "core": true}, {"id": 3, "x": 13.8, "y": 15.2, "w": 2, "h": 3, "adj": [2, 7], "core": true}, {"id": 4, "x": -3.2, "y": 18.5, "w": 5, "h": 3, "adj": [0, 1, 5, 8, 9], "core": false}, {"id": 5, "x": 2.1, "y": 18.5, "w": 2, "h": 3, "adj": [1, 4, 9], "core": false}, {"id": 6, "x": 8.5, "y": 18.5, "w": 2, "h": 3, "adj": [2, 7, 10], "core": false}, {"id": 7, "x": 10.8, "y": 18.5, "w": 4, "h": 3, "adj": [2, 3, 6, 10, 11], "core": false}, {"id": 8, "x": -3.2, "y": 21.8, "w": 4, "h": 2, "adj": [4, 9], "core": false}, {"id": 9, "x": 1.1, "y": 21.8, "w": 3, "h": 2, "adj": [4, 5, 8], "core": false}, {"id": 10, "x": 8.5, "y": 21.8, "w": 3, "h": 2, "adj": [6, 7, 11], "core": false}, {"id": 11, "x": 11.8, "y": 21.8, "w": 3, "h": 2, "adj": [7, 10], "core": false}, {"id": 12, "x": -3.2, "y": -4.0, "w": 5, "h": 3, "adj": [13, 16], "core": true}, {"id": 13, "x": 2.1, "y": -4.0, "w": 2, "h": 3, "adj": [12, 17], "core": true}, {"id": 14, "x": 8.5, "y": -4.0, "w": 5, "h": 3, "adj": [15, 18, 19], "core": true}, {"id": 15, "x": 13.8, "y": -4.0, "w": 2, "h": 3, "adj": [14], "core": true}, {"id": 16, "x": -3.2, "y": -6.3, "w": 5, "h": 2, "adj": [12, 17], "core": false}, {"id": 17, "x": 2.1, "y": -6.3, "w": 2, "h": 2, "adj": [13, 16], "core": false}, {"id": 18, "x": 8.5, "y": -6.3, "w": 2, "h": 2, "adj": [14, 19], "core": false}, {"id": 19, "x": 10.8, "y": -6.3, "w": 3, "h": 2, "adj": [14, 18], "core": false}]'::jsonb, 'parcel_rate', 160, 'parcel_mul', 1.12, 'parcel_lv', 5);
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

create table if not exists public.farm_parcels (
  employee_id uuid not null references public.employees(id) on delete cascade,
  pid int not null,
  use text check (use in ('crop','pen','decor')),
  bought_at timestamptz not null default now(),
  primary key (employee_id, pid)
);
alter table public.farm_parcels enable row level security;
revoke all on public.farm_parcels from anon, public, authenticated;

create or replace function public.farm_parcel_def(p_pid int) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(public.farm_cat()->'parcels') x where (x->>'id')::int = p_pid
$$;
create or replace function public.farm_parcel_cost(p_emp uuid, p_pid int) returns int language sql stable security definer set search_path = public as $$
  select (round((public.farm_parcel_def(p_pid)->>'w')::numeric * (public.farm_parcel_def(p_pid)->>'h')::numeric * (public.farm_cat()->>'parcel_rate')::numeric
    * power((public.farm_cat()->>'parcel_mul')::numeric, (select count(*) from farm_parcels where employee_id = p_emp)) / 10) * 10)::int
$$;
create or replace function public.farm_parcel_pens(p_emp uuid) returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(((public.farm_parcel_def(pid)->>'w')::int / 2) * ((public.farm_parcel_def(pid)->>'h')::int / 2)), 0)::int from farm_parcels where employee_id = p_emp and use = 'pen'
$$;
create or replace function public.farm_pen_total(p_emp uuid) returns int language sql stable security definer set search_path = public as $$
  select coalesce((select pens from farm_profile where employee_id = p_emp), 0) + public.farm_parcel_pens(p_emp)
$$;
-- แปลงผักบนที่ดินขยาย: slot = 1000 + pid*100 + ช่อง
create or replace function public.farm_slot_ok(p_emp uuid, p_slot int, p_plots int) returns boolean language sql stable security definer set search_path = public as $$
  select (p_slot between 1 and p_plots) or (p_slot >= 1000 and exists (select 1 from farm_parcels f where f.employee_id = p_emp and f.use = 'crop' and f.pid = (p_slot - 1000) / 100
    and (p_slot - 1000) % 100 < (public.farm_parcel_def(f.pid)->>'w')::int * (public.farm_parcel_def(f.pid)->>'h')::int))
$$;
revoke execute on function public.farm_parcel_cost(uuid,int), public.farm_parcel_pens(uuid), public.farm_pen_total(uuid), public.farm_slot_ok(uuid,int,int) from public, anon, authenticated;

-- ปลูกผัก / ปลูกให้เพื่อน: ยอมรับ slot บนที่ดินขยาย
do $do$ declare r record; d text; begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'
            and (pg_get_functiondef(p.oid) like '%p_slot > p.plots%' or pg_get_functiondef(p.oid) like '%p_slot > o.plots%') loop
    d := pg_get_functiondef(r.oid);
    d := replace(d, 'if p_slot < 1 or p_slot > p.plots then', 'if not public.farm_slot_ok(e, p_slot, p.plots) then');
    d := replace(d, 'if p_slot < 1 or p_slot > o.plots then', 'if not public.farm_slot_ok(p_owner, p_slot, o.plots) then');
    execute d;
  end loop;
end $do$;

create or replace function public.farm_parcels_of(p_emp uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('pid', pid, 'use', use) order by pid), '[]') from farm_parcels
   where employee_id = coalesce(p_emp, public.my_employee_id()) and public.my_employee_id() is not null
$$;

create or replace function public.farm_parcel_buy(p_pid int) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); p farm_profile; d jsonb := public.farm_parcel_def(p_pid); cost int;
begin
  if d is null then raise exception 'ไม่มีที่ดินแปลงนี้'; end if;
  select * into p from farm_profile where employee_id = e for update;
  if exists (select 1 from farm_parcels where employee_id = e and pid = p_pid) then raise exception 'ซื้อแปลงนี้แล้ว'; end if;
  if not public.is_admin() and public.farm_level(p.xp) < (public.farm_cat()->>'parcel_lv')::int then raise exception 'ต้องเลเวล % ก่อน', public.farm_cat()->>'parcel_lv'; end if;
  if not coalesce((d->>'core')::boolean, false) and not exists (select 1 from farm_parcels f where f.employee_id = e and f.pid in (select jsonb_array_elements_text(d->'adj')::int)) then
    raise exception 'ต้องซื้อที่ดินที่ติดกับพื้นที่บ้านก่อน (ขยายต่อจากแปลงที่มีอยู่)'; end if;
  cost := public.farm_parcel_cost(e, p_pid);
  perform public.farm_spend(e, cost, 'ซื้อที่ดินขยาย ' || (d->>'w') || '×' || (d->>'h'));
  insert into farm_parcels (employee_id, pid) values (e, p_pid);
  perform public.farm_add_xp(e, (d->>'w')::int * (d->>'h')::int * 3);
  return cost;
end $$;

create or replace function public.farm_parcel_use(p_pid int, p_use text) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); f farm_parcels; d jsonb := public.farm_parcel_def(p_pid); capold int; capnew int;
begin
  select * into f from farm_parcels where employee_id = e and pid = p_pid for update;
  if not found then raise exception 'ยังไม่ได้ซื้อที่ดินแปลงนี้'; end if;
  if p_use is not null and p_use not in ('crop','pen','decor') then raise exception 'ใช้งานแบบนี้ไม่ได้'; end if;
  if f.use is not distinct from p_use then return; end if;
  if f.use = 'crop' and exists (select 1 from farm_plots where employee_id = e and crop is not null and slot between 1000 + p_pid * 100 and 1099 + p_pid * 100) then
    raise exception 'ยังมีผักปลูกอยู่ในแปลงนี้ — เก็บเกี่ยวก่อน'; end if;
  if f.use = 'pen' then
    capold := ((d->>'w')::int / 2) * ((d->>'h')::int / 2);
    if public.farm_pen_used(e) > public.farm_pen_total(e) - capold then raise exception 'คอกในที่ดินนี้ยังมีเล้า/คอกสัตว์อยู่ — ย้ายสัตว์ออกก่อน'; end if;
  end if;
  update farm_parcels set use = p_use where employee_id = e and pid = p_pid;
end $$;

-- พื้นที่คอก = ซื้อแยก (pens) + คอกบนที่ดินขยาย
create or replace function public.farm_pen_info() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e uuid := public.my_employee_id(); p farm_profile; c jsonb := public.farm_cat(); mx int; every int := coalesce((c->>'pen_every')::int, 5);
begin
  if e is null then return null; end if;
  select * into p from farm_profile where employee_id = e;
  if not found then return null; end if;
  mx := public.farm_level(p.xp) / every;
  return jsonb_build_object('pens', public.farm_pen_total(e), 'bought', p.pens, 'parcel', public.farm_parcel_pens(e), 'used', public.farm_pen_used(e), 'max', mx, 'per_house', coalesce((c->>'per_house')::int, 5),
    'next_cost', coalesce((c->>'pen_cost')::int, 300) * (p.pens + 1), 'next_level', case when p.pens >= mx then (p.pens + 1) * every end);
end $$;

create or replace function public.farm_buy_decor(p_item text) returns boolean
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); cat jsonb := public.farm_cat(); c jsonb := cat->'decor'->p_item; lv boolean;
begin
  if c ? 'house' then
    lv := (cat->'animals') ? (c->>'house');
    if not lv and exists (select 1 from farm_decor where employee_id = e and item = p_item) then raise exception '% มีแล้ว (มีได้ 1 หลัง)', c->>'n'; end if;
    if lv and public.farm_house_count(e, c->>'house') >= 1 and public.farm_pen_used(e) + 1 > public.farm_pen_total(e) then
      raise exception 'พื้นที่คอกเต็ม — ซื้อพื้นที่คอกเพิ่ม หรือตั้งที่ดินขยายเป็น "คอกสัตว์" (มี % ช่อง ใช้ไป %)', public.farm_pen_total(e), public.farm_pen_used(e); end if;
  end if;
  if c ? 'pet' and not public.farm_has_house(e, c->>'home') then raise exception 'ต้องสร้าง % ก่อน ถึงจะเลี้ยง % ได้', public.farm_house_name(c->>'home'), c->>'n'; end if;
  return public.farm_buy_decor_core(p_item);
end $$;

revoke execute on function public.farm_parcels_of(uuid), public.farm_parcel_buy(int), public.farm_parcel_use(int, text), public.farm_pen_info(), public.farm_buy_decor(text) from public, anon;
grant execute on function public.farm_parcels_of(uuid), public.farm_parcel_buy(int), public.farm_parcel_use(int, text), public.farm_pen_info(), public.farm_buy_decor(text) to authenticated;
notify pgrst, 'reload schema';
