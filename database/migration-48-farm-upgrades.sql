-- =====================================================================
-- Migration 48: ฟาร์ม — ขยายพื้นที่ของแต่ง + ขยายยุ้งฉาง ได้ไม่จำกัด + คลังส่วนตัว + ต้นไม้ตาย/ขวาน/กล่องสุ่ม
--   คลังส่วนตัว: เก็บของแต่งเข้าคลัง (ไม่กินพื้นที่) แล้วค่อยเอาออกมาวาง · ซื้อตอนพื้นที่เต็ม → เข้าคลังอัตโนมัติ
--   ต้นไม้ผล: เก็บผลได้ 6 ครั้งแล้วต้นตาย → ใช้ 🪓 ขวานตัดทิ้ง (ซื้อในร้าน หรือได้จาก 🎁 กล่องสุ่มในฟาร์มเพื่อนบ้าน)
--   กล่องสุ่ม: ไปเยี่ยมฟาร์มเพื่อน บางวันจะเจอกล่อง (ฟาร์มละ 1 ครั้ง/วัน) → ขวาน / เหรียญ / ผัก
--   พื้นที่ของแต่ง = 40 + 10 ต่อที่ดินที่ซื้อ + 15 ต่อการขยาย (เดิมตายตัว 40)
--   ยุ้งฉาง = 50 + 25 ต่อการขยาย (เดิมขยายได้ 10 ครั้ง → ตอนนี้ไม่จำกัด)
--   ค่าขยาย: เหรียญ (เพิ่มขึ้นทุกครั้ง) + ตั้งแต่ครั้งที่ 3 ต้องใช้ผักที่ปลูกได้ตามเลเวล 2 ชนิด
--   ไม่ลบข้อมูลใด ๆ (เพิ่มคอลัมน์ / ฟังก์ชัน)
-- =====================================================================
alter table public.farm_profile add column if not exists decor_lv int not null default 0;
alter table public.farm_decor add column if not exists stored boolean not null default false;
alter table public.farm_decor add column if not exists harv int not null default 0;

create table if not exists public.farm_boxes (
  finder_id uuid not null references public.employees(id) on delete cascade,
  owner_id  uuid not null references public.employees(id) on delete cascade,
  day       date not null,
  reward    jsonb not null default '{}',
  at        timestamptz not null default now(),
  primary key (finder_id, owner_id, day)
);
alter table public.farm_boxes enable row level security;
revoke all on public.farm_boxes from anon, public, authenticated;

do $do$ declare c jsonb := public.farm_cat(); begin
  c := c || '{"tree_life":6,"tools":{"axe":{"n":"ขวาน","e":"🪓","cost":60}}}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

create or replace function public.farm_decor_cap(p_emp uuid) returns int
language sql stable security definer set search_path = public as $$
  select 40 + 10 * coalesce(p.land, 0) + 15 * coalesce(p.decor_lv, 0) from farm_profile p where p.employee_id = p_emp
$$;
create or replace function public.farm_decor_used(p_emp uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from farm_decor where employee_id = p_emp and not stored
$$;

-- สิ่งที่ต้องใช้ในการขยายครั้งถัดไป
create or replace function public.farm_upg_req(p_emp uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p farm_profile; n int; lv int; ks text[]; cnt int; a int; b int; q int; it jsonb := '{}'::jsonb;
begin
  select * into p from farm_profile where employee_id = p_emp;
  if p_kind = 'barn' then n := p.barn_lv + 1; elsif p_kind = 'decor' then n := p.decor_lv + 1; else raise exception 'ไม่รู้จักการขยายนี้'; end if;
  lv := public.farm_level(p.xp);
  select array_agg(k order by (v->>'lv')::int, k) into ks from jsonb_each(public.farm_cat()->'crops') as x(k, v) where (v->>'lv')::int <= lv;
  cnt := coalesce(array_length(ks, 1), 0);
  if n >= 3 and cnt > 0 then
    q := least(3 + n, 30);
    a := ((n * 3 + case when p_kind = 'decor' then 1 else 0 end) % cnt) + 1;
    it := jsonb_build_object(ks[a], q);
    if cnt > 1 then b := ((a - 1 + 1 + (n % (cnt - 1))) % cnt) + 1; if b = a then b := (a % cnt) + 1; end if; it := it || jsonb_build_object(ks[b], q); end if;
  end if;
  return jsonb_build_object('n', n, 'coins', case when p_kind = 'barn' then 150 * n else 200 * n end, 'items', it,
    'add', case when p_kind = 'barn' then 25 else 15 end);
end $$;

create or replace function public.farm_upgrade(p_kind text) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); r jsonb; k text; need int; have int;
begin
  perform 1 from farm_profile where employee_id = e for update;
  r := public.farm_upg_req(e, p_kind);
  for k, need in select key, value::int from jsonb_each_text(r->'items') loop
    select qty into have from farm_items where employee_id = e and item = k for update;
    if coalesce(have, 0) < need then raise exception 'ต้องมี % อีก % ชิ้น', coalesce(public.farm_cat()->'crops'->k->>'n', k), need - coalesce(have, 0); end if;
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

-- ปุ่มขยายยุ้งฉางเดิม → ใช้ระบบใหม่ (ไม่จำกัดครั้ง)
create or replace function public.farm_barn_upgrade() returns int
language plpgsql security definer set search_path = public as $$
begin
  return public.farm_upgrade('barn');
end $$;

create or replace function public.farm_upgrades() returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); p farm_profile;
begin
  select * into p from farm_profile where employee_id = e;
  return jsonb_build_object(
    'barn', jsonb_build_object('lv', p.barn_lv, 'cap', public.farm_barn_cap(e), 'used', public.farm_barn_used(e), 'req', public.farm_upg_req(e, 'barn')),
    'decor', jsonb_build_object('lv', p.decor_lv, 'cap', public.farm_decor_cap(e), 'used', public.farm_decor_used(e), 'stored', (select count(*) from farm_decor where employee_id = e and stored), 'req', public.farm_upg_req(e, 'decor')));
end $$;

drop function if exists public.farm_buy_decor(text);
create or replace function public.farm_buy_decor(p_item text) returns boolean
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); c jsonb := public.farm_cat()->'decor'->p_item; p farm_profile; mx int; cap int; st boolean;
begin
  select * into p from farm_profile where employee_id = e;
  if c is null then raise exception 'ไม่มีของแต่งนี้'; end if;
  if not public.is_admin() and public.farm_level(p.xp) < (c->>'lv')::int then raise exception 'ต้องเลเวล % ก่อน', c->>'lv'; end if;
  cap := public.farm_decor_cap(e);
  mx := case when c ? 'pet' then coalesce((public.farm_cat()->>'max_per_pet')::int, 2) when c ? 'fruit' then coalesce((public.farm_cat()->>'max_per_tree')::int, 4) end;
  if mx is not null and (select count(*) from farm_decor where employee_id = e and item = p_item) >= mx then
    raise exception 'มี% ได้สูงสุด % ต้น/ตัว', c->>'n', mx; end if;
  perform public.farm_spend(e, (c->>'cost')::int, 'ซื้อ' || (c->>'n'));
  st := public.farm_decor_used(e) >= cap;
  insert into farm_decor (employee_id, item, ready_at, stored) values (e, p_item, case when c ? 'fruit' then now() + make_interval(mins => (c->>'min')::int) end, st);
  perform public.farm_add_xp(e, (c->>'xp')::int);
  return st;
end $$;

-- ---------- คลังส่วนตัว ----------
create or replace function public.farm_decor_store(p_id uuid, p_store boolean) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); d farm_decor; cat jsonb := public.farm_cat();
begin
  select * into d from farm_decor where id = p_id and employee_id = e for update;
  if not found then raise exception 'ไม่พบของแต่งชิ้นนี้'; end if;
  if p_store then
    if cat->'decor'->d.item ? 'fruit' and d.harv >= (cat->>'tree_life')::int then raise exception 'ต้นไม้ตายแล้ว — ใช้ 🪓 ขวานตัดทิ้งแทน'; end if;
    update farm_decor set stored = true, gx = null, gy = null where id = p_id;
  else
    if not d.stored then return public.farm_decor_used(e); end if;
    if public.farm_decor_used(e) >= public.farm_decor_cap(e) then raise exception 'พื้นที่วางเต็มแล้ว (% ชิ้น) — ขยายพื้นที่ของแต่ง หรือเก็บชิ้นอื่นเข้าคลังก่อน', public.farm_decor_cap(e); end if;
    update farm_decor set stored = false, gx = null, gy = null where id = p_id;
  end if;
  return public.farm_decor_used(e);
end $$;

create or replace function public.farm_storage() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'item', item, 'harv', harv) order by created_at desc), '[]') from farm_decor where employee_id = public.farm_me() and stored
$$;

-- ---------- ต้นไม้ผล: ตายเมื่อเก็บครบ · ตัดด้วยขวาน ----------
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
  return n;
end $$;

create or replace function public.farm_tool_buy(p_tool text, p_qty int default 1) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); t jsonb := public.farm_cat()->'tools'->p_tool; q int := greatest(1, least(coalesce(p_qty, 1), 10));
begin
  if t is null then raise exception 'ไม่มีเครื่องมือนี้'; end if;
  if public.farm_barn_used(e) + q > public.farm_barn_cap(e) then raise exception 'ยุ้งฉางเต็ม — ขายของหรือขยายยุ้งฉางก่อน'; end if;
  perform public.farm_spend(e, (t->>'cost')::int * q, 'ซื้อ' || (t->>'n') || ' x' || q);
  perform public.farm_add_item(e, p_tool, q);
  return (select qty from farm_items where employee_id = e and item = p_tool);
end $$;

create or replace function public.farm_tree_chop(p_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); d farm_decor; c jsonb; have int; cn int;
begin
  select * into d from farm_decor where id = p_id and employee_id = e for update;
  if not found then raise exception 'ไม่พบต้นไม้นี้'; end if;
  c := public.farm_cat()->'decor'->d.item;
  if not (c ? 'fruit') then raise exception 'ตัดได้เฉพาะต้นไม้ผล'; end if;
  if d.harv < coalesce((public.farm_cat()->>'tree_life')::int, 6) then raise exception 'ต้นไม้ยังไม่ตาย'; end if;
  select qty into have from farm_items where employee_id = e and item = 'axe' for update;
  if coalesce(have, 0) < 1 then raise exception 'ต้องมี 🪓 ขวาน — ซื้อในร้านค้า หรือหาจากกล่องสุ่มในฟาร์มเพื่อนบ้าน'; end if;
  update farm_items set qty = qty - 1 where employee_id = e and item = 'axe';
  delete from farm_decor where id = p_id;
  cn := 5 + ((c->>'cost')::int / 10);
  insert into farm_ledger (employee_id, delta, reason) values (e, cn, 'ตัดต้นไม้ ' || (c->>'n'));
  perform public.farm_add_xp(e, 5);
  return cn;
end $$;

-- ---------- กล่องสุ่มในฟาร์มเพื่อนบ้าน ----------
create or replace function public.farm_box_here(p_finder uuid, p_owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_finder is not null and p_owner is not null and p_finder <> p_owner
    and abs(hashtext(p_finder::text || p_owner::text || public.farm_today()::text)) % 100 < 45
    and not exists (select 1 from farm_boxes where finder_id = p_finder and owner_id = p_owner and day = public.farm_today())
$$;

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
  return rw;
end $$;

-- ข้อมูลแปลง + กล่องสุ่ม (เพิ่ม 'box')
create or replace function public.farm_plot_info(p_emp uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); e uuid; td timestamptz := (public.farm_today())::timestamp at time zone 'Asia/Bangkok';
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  e := coalesce(p_emp, me);
  return jsonb_build_object(
    'plots', coalesce((select jsonb_agg(jsonb_build_object('slot', p.slot,
        'stolen_by', (select coalesce(nullif(x.display_name, ''), x.employee_no) from employees x where x.id = p.stolen_by), 'stolen_at', p.stolen_at,
        'planted_by', (select coalesce(nullif(x.display_name, ''), x.employee_no) from employees x where x.id = p.planted_by), 'mine', p.planted_by = me))
      from farm_plots p where p.employee_id = e and (p.stolen_by is not null or p.planted_by is not null)), '[]'),
    'debt', coalesce((select steal_debt from farm_profile where employee_id = e), 0),
    'my_debt', coalesce((select steal_debt from farm_profile where employee_id = me), 0),
    'my_steals_today', (select count(*) from farm_thefts where thief_id = me and at >= td),
    'my_steals_here', (select count(*) from farm_thefts where thief_id = me and owner_id = e and at >= td),
    'box', public.farm_box_here(me, e),
    'thefts', case when e = me then coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'crop', t.crop, 'at', t.at,
        'thief', (select coalesce(nullif(x.display_name, ''), x.employee_no) from employees x where x.id = t.thief_id)) order by t.at desc)
      from (select * from farm_thefts where owner_id = e and at > now() - interval '2 days' order by at desc limit 20) t), '[]') else '[]'::jsonb end);
end $$;

-- farm_get: ของแต่งในคลังไม่แสดงบนแผนที่ · ส่งจำนวนครั้งที่เก็บผลของต้นไม้ (harv)
create or replace function public.farm_get(p_emp uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); e uuid; own boolean; p farm_profile; td date := (now() at time zone 'Asia/Bangkok')::date; r jsonb;
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  e := coalesce(p_emp, me); own := e = me;
  if own then insert into farm_profile (employee_id) values (me) on conflict do nothing; end if;
  select * into p from farm_profile where employee_id = e;
  if not found then raise exception 'เพื่อนคนนี้ยังไม่ได้เริ่มทำฟาร์ม'; end if;
  r := jsonb_build_object(
    'own', own, 'emp', e, 'now', now(),
    'name', (select display_name from employees where id = e),
    'avatar', (select avatar from employees where id = e),
    'dept', (select d.name from employees x left join departments d on d.id = x.department_id where x.id = e),
    'plots', p.plots, 'land', p.land, 'boost_until', case when p.boost_until > now() then p.boost_until end, 'xp', p.xp, 'level', public.farm_level(p.xp), 'likes', p.likes,
    'decor_cap', public.farm_decor_cap(e), 'stored', (select count(*) from farm_decor where employee_id = e and stored),
    'field', coalesce((select jsonb_agg(jsonb_build_object('slot', slot, 'crop', crop, 'ready_at', ready_at) order by slot) from farm_plots where employee_id = e and crop is not null), '[]'),
    'animals', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'animal', animal, 'ready_at', ready_at) order by created_at) from farm_animals where employee_id = e), '[]'),
    'machines', coalesce((select jsonb_agg(machine order by machine) from farm_machines where employee_id = e), '[]'),
    'stall', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'slot', s.slot, 'item', s.item, 'qty', s.qty, 'price', s.price, 'sold', s.buyer_id is not null, 'buyer', case when own then (select display_name from employees where id = s.buyer_id) end) order by s.slot) from farm_stall s where s.seller_id = e and (own or s.buyer_id is null)), '[]'),
    'decor', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item', item, 'gx', gx, 'gy', gy, 'ready_at', ready_at, 'harv', harv) order by created_at) from farm_decor where employee_id = e and not stored), '[]'));
  if own then
    r := r || jsonb_build_object(
      'jobs', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'machine', machine, 'product', product, 'ready_at', ready_at) order by ready_at) from farm_jobs where employee_id = me), '[]'),
      'coins', public.farm_coins(me),
      'items', coalesce((select jsonb_object_agg(item, qty) from farm_items where employee_id = me and qty > 0), '{}'),
      'kpi_today', (select coins from public.farm_kpi_days(me, td, td)),
      'kpi_week', coalesce((select sum(coins) from public.farm_kpi_days(me, td - 6, td)), 0),
      'kpi_total', coalesce((select sum(coins) from public.farm_kpi_days(me)), 0));
  else
    r := r || jsonb_build_object('liked', exists (select 1 from farm_likes where owner_id = e and liker_id = me and day = td));
  end if;
  return r;
end $$;

-- ย้ายของแต่ง: ห้ามย้ายชิ้นที่อยู่ในคลัง
create or replace function public.farm_move_decor(p_id uuid, p_x int, p_y int, p_ox int default null, p_oy int default null) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); d farm_decor; o farm_decor;
begin
  select * into d from farm_decor where id = p_id and employee_id = e and not stored for update;
  if not found then raise exception 'ไม่พบของแต่งชิ้นนี้'; end if;
  if p_x < 0 or p_x > 11 or p_y < 0 or p_y > 11 then raise exception 'วางนอกฟาร์มไม่ได้'; end if;
  select * into o from farm_decor where employee_id = e and gx = p_x and gy = p_y and id <> p_id and not stored limit 1;
  if found then update farm_decor set gx = coalesce(d.gx, p_ox), gy = coalesce(d.gy, p_oy) where id = o.id; end if;
  update farm_decor set gx = p_x, gy = p_y where id = p_id;
end $$;

revoke execute on function public.farm_decor_cap(uuid), public.farm_decor_used(uuid), public.farm_upg_req(uuid, text), public.farm_box_here(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.farm_decor_store(uuid, boolean), public.farm_storage(), public.farm_tool_buy(text, int), public.farm_tree_chop(uuid), public.farm_box_open(uuid) from public, anon;
revoke execute on function public.farm_buy_decor(text) from public, anon;
grant execute on function public.farm_buy_decor(text) to authenticated;
grant execute on function public.farm_decor_store(uuid, boolean), public.farm_storage(), public.farm_tool_buy(text, int), public.farm_tree_chop(uuid), public.farm_box_open(uuid) to authenticated;
revoke execute on function public.farm_upgrade(text), public.farm_upgrades() from public, anon;
grant execute on function public.farm_upgrade(text), public.farm_upgrades() to authenticated;
notify pgrst, 'reload schema';
