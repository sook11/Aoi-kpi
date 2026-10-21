-- =====================================================================
-- Migration 53: ฟาร์ม — คำสั่งซื้อ
--  • ส่งของได้ไม่จำกัดรอบต่อวัน (ยกเลิกเพดาน 8 ใบ/วัน จาก migration 51)
--  • XP ของใบสั่งคิดตาม "ความยาก" = เวลาที่ต้องใช้ผลิตของแต่ละชิ้น
--      ผัก = เวลาปลูก · ผลผลิตสัตว์ = เวลาต่อรอบ · ผลไม้ = เวลาต่อรอบ ÷ จำนวนผล
--      ของจากเครื่องจักร = เวลาเครื่อง + เวลาของวัตถุดิบทั้งหมด (คิดต่อเนื่อง)
--    XP ต่อชิ้น = 0.2 × (นาที)^0.7  → ของง่ายได้น้อย ของยาก/นานได้มากกว่า
--      เช่น ข้าวสาลี ~0.6 · ไข่ ~3.5 · นม ~7.6 · ชีส ~17 · เสื้อไหมพรม ~21 XP ต่อชิ้น
--  • เหรียญเท่าเดิม (ราคาขาย × 1.05)
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
create or replace function public.farm_effort(p_item text, p_d int default 0) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.farm_cat(); m jsonb; r jsonb; e numeric; k text; q int;
begin
  if p_d > 4 then return 10; end if;
  if c->'crops' ? p_item then return coalesce((c->'crops'->p_item->>'min')::numeric, 10); end if;
  select (value->>'min')::numeric into e from jsonb_each(c->'animals') where value->>'prod' = p_item limit 1;
  if e is not null then return e; end if;
  select (value->>'min')::numeric / greatest(coalesce((value->>'yield')::numeric, 1), 1) into e
    from jsonb_each(c->'decor') where value->>'fruit' = p_item limit 1;
  if e is not null then return e; end if;
  for m in select value from jsonb_each(coalesce(c->'machines', '{}')) loop
    r := m->'recipes'->p_item;
    if r is not null then
      e := coalesce((r->>'min')::numeric, 10);
      for k, q in select key, value::int from jsonb_each_text(coalesce(r->'in', '{}')) loop
        e := e + q * public.farm_effort(k, p_d + 1);
      end loop;
      return e;
    end if;
  end loop;
  return 10;
end $$;

create or replace function public.farm_order_make(p_emp uuid, p_slot int, p_wait interval) returns void
language plpgsql security definer set search_path = public as $$
declare cat jsonb := public.farm_cat(); lv int; pool text[]; pick text[]; k text; q int; items jsonb := '{}'; val int := 0; n int; sell int; xpf numeric := 0;
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
    xpf := xpf + q * 0.2 * power(public.farm_effort(k), 0.7);
  end loop;
  insert into farm_orders (employee_id, slot, items, coins, xp, ready_at)
  values (p_emp, p_slot, items, ceil(val * 1.05)::int, 1 + round(xpf)::int, now() + p_wait)
  on conflict (employee_id, slot) do update set items = excluded.items, coins = excluded.coins, xp = excluded.xp, ready_at = excluded.ready_at;
end $$;

-- ใบสั่งที่ค้างอยู่: คิด XP ใหม่ตามความยาก
update public.farm_orders o set xp = 1 + round(coalesce((
  select sum(value::int * 0.2 * power(public.farm_effort(key), 0.7)) from jsonb_each_text(o.items)), 0))::int;

-- ยกเลิกเพดานรายวัน
do $do$ declare c jsonb := public.farm_cat(); begin
  c := c || '{"orders_per_day":0}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

create or replace function public.farm_order_deliver(p_slot int) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); o farm_orders; k text; need int; have int; mx int := coalesce((public.farm_cat()->>'orders_per_day')::int, 0);
begin
  if mx > 0 and public.farm_orders_today(e) >= mx then raise exception 'วันนี้ส่งคำสั่งซื้อครบ % ใบแล้ว พรุ่งนี้มาส่งใหม่นะ', mx; end if;
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

revoke execute on function public.farm_effort(text, int) from public, anon;
grant execute on function public.farm_effort(text, int) to authenticated;
notify pgrst, 'reload schema';
