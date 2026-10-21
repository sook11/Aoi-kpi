-- =====================================================================
-- Migration 55: ฟาร์ม — ช่องร้านริมทางเพิ่มได้
--  • ช่องเริ่มต้น 6 ช่อง (เท่าเดิม) + 1 ช่องทุก ๆ 10 เลเวล (สูงสุด +6 จากเลเวล)
--  • ปลดล็อกพิเศษซื้อเพิ่มได้อีก 4 ช่อง: 800 / 2,000 / 4,000 / 7,000 เหรียญ
--  • รวมสูงสุด 16 ช่อง
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
alter table public.farm_stall drop constraint if exists farm_stall_slot_check;
alter table public.farm_stall add constraint farm_stall_slot_check check (slot between 1 and 16);
alter table public.farm_profile add column if not exists stall_extra int not null default 0;

create or replace function public.farm_stall_slots(p_emp uuid) returns int
language sql stable security definer set search_path = public as $$
  select least(16, 6 + least(6, public.farm_level(p.xp) / 10) + least(4, coalesce(p.stall_extra, 0)))
    from farm_profile p where p.employee_id = p_emp
$$;

create or replace function public.farm_stall_info() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e uuid := public.my_employee_id(); p farm_profile; costs int[] := array[800, 2000, 4000, 7000]; lvs int;
begin
  if e is null then return null; end if;
  select * into p from farm_profile where employee_id = e;
  if not found then return null; end if;
  lvs := least(6, public.farm_level(p.xp) / 10);
  return jsonb_build_object('slots', public.farm_stall_slots(e), 'base', 6, 'from_level', lvs, 'extra', p.stall_extra,
    'next_cost', case when p.stall_extra < 4 then costs[p.stall_extra + 1] end,
    'next_level', case when lvs < 6 then (lvs + 1) * 10 end, 'max', 16);
end $$;

create or replace function public.farm_stall_unlock() returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); p farm_profile; costs int[] := array[800, 2000, 4000, 7000];
begin
  select * into p from farm_profile where employee_id = e for update;
  if p.stall_extra >= 4 then raise exception 'ปลดล็อกช่องพิเศษครบแล้ว'; end if;
  perform public.farm_spend(e, costs[p.stall_extra + 1], 'ปลดล็อกช่องร้านริมทาง');
  update farm_profile set stall_extra = stall_extra + 1 where employee_id = e;
  return public.farm_stall_slots(e);
end $$;

create or replace function public.farm_stall_list(p_slot int, p_item text, p_qty int, p_price int) returns bigint
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); pr int := public.farm_item_price(p_item); have int; nid bigint;
begin
  if pr is null then raise exception 'ขายของนี้ไม่ได้'; end if;
  if p_slot < 1 or p_slot > public.farm_stall_slots(e) then raise exception 'ช่องนี้ยังไม่ได้ปลดล็อก'; end if;
  if coalesce(p_qty, 0) < 1 or p_qty > 10 then raise exception 'จำนวนต้องอยู่ระหว่าง 1–10'; end if;
  if coalesce(p_price, 0) < 1 or p_price > ceil(pr * p_qty * 2.5) then raise exception 'ราคาต้องอยู่ระหว่าง 1–%', ceil(pr * p_qty * 2.5)::int; end if;
  if exists (select 1 from farm_stall where seller_id = e and slot = p_slot) then raise exception 'ช่องนี้มีของอยู่แล้ว'; end if;
  select qty into have from farm_items where employee_id = e and item = p_item for update;
  if coalesce(have, 0) < p_qty then raise exception 'ของในยุ้งฉางไม่พอ'; end if;
  update farm_items set qty = qty - p_qty where employee_id = e and item = p_item;
  insert into farm_stall (seller_id, slot, item, qty, price) values (e, p_slot, p_item, p_qty, p_price) returning id into nid;
  return nid;
end $$;

revoke execute on function public.farm_stall_slots(uuid) from public, anon, authenticated;
revoke execute on function public.farm_stall_info(), public.farm_stall_unlock() from public, anon;
grant execute on function public.farm_stall_info(), public.farm_stall_unlock() to authenticated;
notify pgrst, 'reload schema';
