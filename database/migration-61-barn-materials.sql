-- =====================================================================
-- Migration 61: ยุ้งฉาง — ขยายด้วยไอเทมสะสม + ความจุเพิ่มตามเลเวล
--  • ไอเทมวัสดุ 3 ชนิด: 🔩 น็อตเกลียว · 🧱 อิฐ · ⛓️ โซ่ (ขายได้ชิ้นละ 25 / ตั้งขายที่ร้านริมทางได้)
--      สุ่มได้จาก: เก็บผัก · เก็บผลผลิตสัตว์ · เก็บผลไม้ · เก็บของจากเครื่องจักร · ส่งคำสั่งซื้อ · กล่องสุ่ม · ตกปลา
--  • ขยายยุ้งฉาง (+25 ช่อง): ใช้วัสดุ 3 ชนิด (จำนวนเพิ่มขึ้นทีละนิด) + เหรียญเล็กน้อย — ไม่ต้องใช้ผักแล้ว
--  • ความจุเพิ่มตามเลเวล: +25 ช่อง ทุก ๆ 10 เลเวล (Lv10, 20, 30 …) อัตโนมัติ
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := jsonb_set(c, '{products,m_bolt}',  '{"n":"น็อตเกลียว","e":"🔩","sell":25,"mat":true}'::jsonb);
  c := jsonb_set(c, '{products,m_brick}', '{"n":"อิฐ","e":"🧱","sell":25,"mat":true}'::jsonb);
  c := jsonb_set(c, '{products,m_chain}', '{"n":"โซ่","e":"⛓️","sell":25,"mat":true}'::jsonb);
  c := c || '{"barn_mats":["m_bolt","m_brick","m_chain"],"barn_lv_bonus":25}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

create table if not exists public.farm_mat_log (
  id          bigserial primary key,
  employee_id uuid not null references public.employees(id) on delete cascade,
  item        text not null,
  at          timestamptz not null default now(),
  seen        boolean not null default false
);
create index if not exists farm_mat_log_emp_idx on public.farm_mat_log (employee_id) where not seen;
alter table public.farm_mat_log enable row level security;
revoke all on public.farm_mat_log from anon, public, authenticated;

-- ความจุยุ้งฉาง = 50 + 25 ต่อการขยาย + 25 ทุก ๆ 10 เลเวล
create or replace function public.farm_barn_cap(p_emp uuid) returns int
language sql stable security definer set search_path = public as $$
  select 50 + 25 * coalesce(p.barn_lv, 0) + 25 * (public.farm_level(p.xp) / 10) from farm_profile p where p.employee_id = p_emp
$$;

-- สุ่มได้วัสดุ 1 ชิ้น (ไม่ติดความจุยุ้งฉาง)
create or replace function public.farm_mat_drop(p_emp uuid, p_chance numeric) returns text
language plpgsql security definer set search_path = public as $$
declare k text; m jsonb := public.farm_cat()->'barn_mats';
begin
  if p_emp is null or m is null or random() >= coalesce(p_chance, 0) then return null; end if;
  k := m->>floor(random() * jsonb_array_length(m))::int;
  perform public.farm_add_item(p_emp, k, 1);
  insert into farm_mat_log (employee_id, item) values (p_emp, k);
  return k;
end $$;

-- แจ้งเตือนวัสดุที่เพิ่งได้ (อ่านแล้วล้าง)
create or replace function public.farm_mat_pop() returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.my_employee_id(); r jsonb;
begin
  if e is null then return '[]'::jsonb; end if;
  with u as (update farm_mat_log set seen = true where employee_id = e and not seen returning item)
  select coalesce(jsonb_agg(item), '[]'::jsonb) into r from u;
  return r;
end $$;

-- สิ่งที่ต้องใช้ขยายครั้งถัดไป: ยุ้งฉาง = วัสดุ 3 ชนิด + เหรียญเล็กน้อย · พื้นที่ของแต่ง = เหมือนเดิม
create or replace function public.farm_upg_req(p_emp uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p farm_profile; n int; lv int; ks text[]; cnt int; a int; b int; q int; it jsonb := '{}'::jsonb; mk text;
begin
  select * into p from farm_profile where employee_id = p_emp;
  if p_kind = 'barn' then
    n := p.barn_lv + 1; q := least(1 + floor(n * 0.7)::int, 20);
    for mk in select jsonb_array_elements_text(public.farm_cat()->'barn_mats') loop it := it || jsonb_build_object(mk, q); end loop;
    return jsonb_build_object('n', n, 'coins', 50 * n, 'items', it, 'add', 25,
      'lv_bonus', 25 * (public.farm_level(p.xp) / 10), 'next_lv', (public.farm_level(p.xp) / 10 + 1) * 10);
  elsif p_kind = 'decor' then n := p.decor_lv + 1; else raise exception 'ไม่รู้จักการขยายนี้'; end if;
  lv := public.farm_level(p.xp);
  select array_agg(k order by (v->>'lv')::int, k) into ks from jsonb_each(public.farm_cat()->'crops') as x(k, v) where (v->>'lv')::int <= lv;
  cnt := coalesce(array_length(ks, 1), 0);
  if n >= 3 and cnt > 0 then
    q := least(3 + n, 30);
    a := ((n * 3 + 1) % cnt) + 1;
    it := jsonb_build_object(ks[a], q);
    if cnt > 1 then b := ((a - 1 + 1 + (n % (cnt - 1))) % cnt) + 1; if b = a then b := (a % cnt) + 1; end if; it := it || jsonb_build_object(ks[b], q); end if;
  end if;
  return jsonb_build_object('n', n, 'coins', 200 * n, 'items', it, 'add', 15);
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
  if n > 0 then perform public.farm_mat_drop(e, least(0.6, 0.03 * n)); end if;
  return n;
end $$;

create or replace function public.farm_collect(p_id uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); x record; n int := 0; cat jsonb := public.farm_cat()->'animals';
begin
  for x in select * from farm_animals where employee_id = e and ready_at <= now() and (p_id is null or id = p_id) order by created_at loop
    if public.farm_barn_used(e) >= public.farm_barn_cap(e) then
      if n = 0 then raise exception 'ยุ้งฉางเต็มแล้ว (% ชิ้น) — ขายของ ส่งคำสั่งซื้อ หรือขยายยุ้งฉางก่อน', public.farm_barn_cap(e); end if;
      exit;
    end if;
    perform public.farm_add_item(e, cat->x.animal->>'prod', 1);
    perform public.farm_add_xp(e, (cat->x.animal->>'xp')::int);
    update farm_animals set ready_at = null where id = x.id;
    n := n + 1;
  end loop;
  if p_id is not null and n = 0 then raise exception 'ยังไม่พร้อม'; end if;
  if n > 0 then perform public.farm_mat_drop(e, least(0.5, 0.05 * n)); end if;
  return n;
end $$;

create or replace function public.farm_tree_harvest(p_id uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); cat jsonb := public.farm_cat()->'decor'; life int := coalesce((public.farm_cat()->>'tree_life')::int, 6); x record; n int := 0; y int;
begin
  for x in select * from farm_decor where employee_id = e and not stored and harv < life and (p_id is null or id = p_id) and cat->item ? 'fruit' and coalesce(ready_at, now()) <= now() order by created_at loop
    y := coalesce((cat->x.item->>'yield')::int, 1);
    if public.farm_barn_used(e) + y > public.farm_barn_cap(e) then
      if n = 0 then raise exception 'ยุ้งฉางเต็มแล้ว (% ชิ้น) — ขายของ ส่งคำสั่งซื้อ หรือขยายยุ้งฉางก่อน', public.farm_barn_cap(e); end if;
      exit;
    end if;
    perform public.farm_add_item(e, cat->x.item->>'fruit', y);
    perform public.farm_add_xp(e, 2);
    update farm_decor set harv = harv + 1, ready_at = case when harv + 1 >= life then null else now() + make_interval(mins => (cat->x.item->>'min')::int) end where id = x.id;
    n := n + y;
  end loop;
  if p_id is not null and n = 0 then raise exception 'ยังไม่สุก'; end if;
  if n > 0 then perform public.farm_mat_drop(e, least(0.5, 0.04 * n)); end if;
  return n;
end $$;

create or replace function public.farm_job_collect(p_machine text default null) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); cat jsonb := public.farm_cat(); x record; n int := 0;
begin
  for x in select * from farm_jobs where employee_id = e and ready_at <= now() and (p_machine is null or machine = p_machine) order by ready_at loop
    if public.farm_barn_used(e) >= public.farm_barn_cap(e) then
      if n = 0 then raise exception 'ยุ้งฉางเต็มแล้ว (% ชิ้น) — ขายของ ส่งคำสั่งซื้อ หรือขยายยุ้งฉางก่อน', public.farm_barn_cap(e); end if;
      exit;
    end if;
    perform public.farm_add_item(e, x.product, 1);
    perform public.farm_add_xp(e, coalesce((cat->'machines'->x.machine->'recipes'->x.product->>'xp')::int, 2));
    delete from farm_jobs where id = x.id;
    n := n + 1;
  end loop;
  if p_machine is not null and n = 0 then raise exception 'ยังไม่เสร็จ'; end if;
  if n > 0 then perform public.farm_mat_drop(e, least(0.6, 0.08 * n)); end if;
  return n;
end $$;

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
  perform public.farm_mat_drop(e, 0.35);
  return o.coins;
end $$;

create or replace function public.farm_box_open(p_owner uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); r int := floor(random() * 100); rw jsonb; k text; lv int;
begin
  if not public.farm_box_here(e, p_owner) then raise exception 'ไม่มีกล่องในฟาร์มนี้แล้ววันนี้'; end if;
  if r < 45 then
    if public.farm_barn_used(e) >= public.farm_barn_cap(e) then rw := jsonb_build_object('coins', 40); else perform public.farm_add_item(e, 'axe', 1); rw := jsonb_build_object('item', 'axe', 'qty', 1); end if;
  elsif r < 80 then rw := jsonb_build_object('coins', 20 + floor(random() * 41)::int);
  else
    select public.farm_level(xp) into lv from farm_profile where employee_id = e;
    select key into k from jsonb_each(public.farm_cat()->'crops') where (value->>'lv')::int <= coalesce(lv, 1) order by random() limit 1;
    if k is null or public.farm_barn_used(e) + 3 > public.farm_barn_cap(e) then rw := jsonb_build_object('coins', 30); else perform public.farm_add_item(e, k, 3); rw := jsonb_build_object('item', k, 'qty', 3); end if;
  end if;
  if rw ? 'coins' then insert into farm_ledger (employee_id, delta, reason) values (e, (rw->>'coins')::int, 'กล่องสุ่มจากฟาร์มเพื่อน'); end if;
  insert into farm_boxes (finder_id, owner_id, day, reward) values (e, p_owner, public.farm_today(), rw);
  perform public.farm_add_xp(e, 2);
  perform public.farm_mat_drop(e, 0.5);
  return rw;
end $$;

create or replace function public.fish_land(p_id bigint, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me(); x fish_catches; c jsonb := public.farm_cat(); f jsonb; best numeric; rec boolean; gold boolean := false; gid date;
begin
  select * into x from fish_catches where id = p_id and employee_id = e for update;
  if not found or x.status <> 'hook' then raise exception 'ปลาหลุดไปแล้ว'; end if;
  if x.created_at < now() - interval '90 seconds' then update fish_catches set status = 'lost' where id = p_id; raise exception 'ปลาหลุดไปแล้ว'; end if;
  f := c->'fish'->x.fish;
  if not p_ok then
    update fish_catches set status = 'lost' where id = p_id;
    return jsonb_build_object('ok', false, 'fish', x.fish, 'r', (f->>'r')::int, 'gold', x.fish = 'f_goldday');
  end if;
  if public.farm_barn_used(e) >= public.farm_barn_cap(e) then raise exception 'ยุ้งฉางเต็ม — ขายของก่อนแล้วค่อยตกต่อ'; end if;
  if x.fish = 'f_goldday' then
    insert into fish_gold (day, winner_id, catch_id, weight) values (public.farm_today(), e, x.id, x.weight) on conflict (day) do nothing returning day into gid;
    if gid is null then
      -- มีคนตกปลาทองไปก่อนแล้ว → ได้ปลาตำนานธรรมดาแทน
      select key into x.fish from jsonb_each(c->'fish') where (value->>'r')::int = 5 and not coalesce((value->>'daily')::boolean, false) order by random() limit 1;
      f := c->'fish'->x.fish;
      update fish_catches set fish = x.fish, points = 50 where id = p_id;
      x.points := 50;
    else gold := true; end if;
  end if;
  select max(weight) into best from fish_catches where employee_id = e and fish = x.fish and status = 'landed';
  select x.weight > coalesce(max(weight), 0) into rec from fish_catches where fish = x.fish and status = 'landed';
  update fish_catches set status = 'landed', landed_at = now() where id = p_id;
  perform public.farm_add_item(e, x.fish, 1);
  perform public.farm_add_xp(e, (f->>'xp')::int);
  perform public.farm_mat_drop(e, 0.05);
  return jsonb_build_object('ok', true, 'fish', x.fish, 'r', (f->>'r')::int, 'weight', x.weight, 'points', x.points, 'xp', (f->>'xp')::int,
    'new_best', best is null or x.weight > best, 'first', best is null, 'record', rec, 'gold', gold);
end $$;

create or replace function public.farm_upgrade(p_kind text) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); r jsonb; k text; need int; have int;
begin
  perform 1 from farm_profile where employee_id = e for update;
  r := public.farm_upg_req(e, p_kind);
  for k, need in select key, value::int from jsonb_each_text(r->'items') loop
    select qty into have from farm_items where employee_id = e and item = k for update;
    if coalesce(have, 0) < need then raise exception 'ต้องมี % อีก % ชิ้น', coalesce(public.farm_cat()->'crops'->k->>'n', public.farm_cat()->'products'->k->>'n', k), need - coalesce(have, 0); end if;
  end loop;
  perform public.farm_spend(e, (r->>'coins')::int, case when p_kind = 'barn' then 'ขยายยุ้งฉาง ครั้งที่ ' else 'ขยายพื้นที่ของแต่ง ครั้งที่ ' end || (r->>'n'));
  for k, need in select key, value::int from jsonb_each_text(r->'items') loop
    update farm_items set qty = qty - need where employee_id = e and item = k;
  end loop;
  if p_kind = 'barn' then
    update farm_profile set barn_lv = barn_lv + 1 where employee_id = e;
    perform public.farm_add_xp(e, 5);
    return public.farm_barn_cap(e);
  end if;
  update farm_profile set decor_lv = decor_lv + 1 where employee_id = e;
  perform public.farm_add_xp(e, 5);
  return public.farm_decor_cap(e);
end $$;

revoke execute on function public.farm_mat_drop(uuid, numeric) from public, anon, authenticated;
revoke execute on function public.farm_mat_pop() from public, anon;
grant execute on function public.farm_mat_pop() to authenticated;
notify pgrst, 'reload schema';
