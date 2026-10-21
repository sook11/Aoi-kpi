-- =====================================================================
-- Migration 54: ฟาร์ม — ปลูกจากผลผลิตของตัวเอง + ผักขาดตลาด
--  • เก็บเกี่ยว 1 แปลง ได้ผลผลิต 2 ชิ้น (เดิม 1)
--  • ปลูก: ถ้ามีผักชนิดนั้นในยุ้งฉาง ใช้ 1 ชิ้นเป็นเมล็ด (ไม่เสียเหรียญ)
--          ถ้าไม่มี ซื้อเมล็ดจากร้านด้วยเหรียญเหมือนเดิม
--  • ผักขาดตลาด: ทุกวันสุ่ม 3 ชนิด (เลเวล 2 ขึ้นไป) ที่ร้านไม่มีเมล็ดขาย
--          ต้องใช้ผลผลิตในยุ้ง หรือไปซื้อจากร้านริมทางของเพื่อนบ้านมาปลูก
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
create or replace function public.farm_short_today() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(key order by key), '{}') from (
    select key from jsonb_each(public.farm_cat()->'crops')
     where (value->>'lv')::int >= 2
     order by md5(public.farm_today()::text || key) limit 3) z
$$;

create or replace function public.farm_plant(p_slot int, p_crop text) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); c jsonb := public.farm_cat()->'crops'->p_crop; p farm_profile; secs numeric; have int;
begin
  select * into p from farm_profile where employee_id = e;
  if c is null then raise exception 'ไม่มีพืชนี้'; end if;
  if p_slot < 1 or p_slot > p.plots then raise exception 'แปลงนี้ยังไม่ได้ปลดล็อก'; end if;
  if not public.is_admin() and public.farm_level(p.xp) < (c->>'lv')::int then raise exception 'ต้องเลเวล % ก่อน', c->>'lv'; end if;
  if exists (select 1 from farm_plots where employee_id = e and slot = p_slot and crop is not null) then raise exception 'แปลงนี้ปลูกอยู่แล้ว'; end if;
  select qty into have from farm_items where employee_id = e and item = p_crop for update;
  if coalesce(have, 0) >= 1 then
    update farm_items set qty = qty - 1 where employee_id = e and item = p_crop;
  elsif p_crop = any(public.farm_short_today()) then
    raise exception '% ขาดตลาดวันนี้ — ไปซื้อจากร้านริมทางของเพื่อนบ้าน (🗞️ ป้ายตลาด) แล้วนำมาปลูก', c->>'n';
  else
    perform public.farm_spend(e, (c->>'cost')::int, 'ซื้อเมล็ด ' || (c->>'n'));
  end if;
  secs := (c->>'min')::int * 60 * case when p.boost_until > now() then 0.5 else 1 end;
  insert into farm_plots (employee_id, slot, crop, ready_at) values (e, p_slot, p_crop, now() + make_interval(secs => secs))
  on conflict (employee_id, slot) do update set crop = excluded.crop, ready_at = excluded.ready_at;
end $$;

create or replace function public.farm_harvest(p_slot int default null) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); x record; n int := 0; cat jsonb := public.farm_cat()->'crops'; y int := coalesce((public.farm_cat()->>'crop_yield')::int, 2);
begin
  for x in select * from farm_plots where employee_id = e and crop is not null and ready_at <= now() and (p_slot is null or slot = p_slot) order by slot loop
    if public.farm_barn_used(e) + y > public.farm_barn_cap(e) then
      if n = 0 then raise exception 'ยุ้งฉางเต็มแล้ว (% ชิ้น) — ขายของ ส่งคำสั่งซื้อ หรือขยายยุ้งฉางก่อน', public.farm_barn_cap(e); end if;
      exit;
    end if;
    perform public.farm_add_item(e, x.crop, y);
    perform public.farm_add_xp(e, (cat->x.crop->>'xp')::int);
    update farm_plots set crop = null, ready_at = null where employee_id = e and slot = x.slot;
    n := n + y;
  end loop;
  if p_slot is not null and n = 0 then raise exception 'ยังไม่สุก'; end if;
  return n;
end $$;

do $do$ declare c jsonb := public.farm_cat(); begin
  c := c || '{"crop_yield":2}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

revoke execute on function public.farm_short_today() from public, anon;
grant execute on function public.farm_short_today() to authenticated;
notify pgrst, 'reload schema';
