-- =====================================================================
-- Migration 59: ทะเลสาบตกปลา — ต้องใช้เหยื่อทุกครั้ง + ปลาทองประจำวัน
--  • เหวี่ยงเบ็ดต้องใช้เหยื่อ 1 ชิ้นทุกครั้ง (ไม่มีเหวี่ยงฟรีแล้ว) — มีเหยื่อเหวี่ยงได้เรื่อย ๆ จนกว่าจะหมด
--  • เหยื่อแต่ละแบบมีโอกาสได้ปลาแต่ละระดับต่างกัน: ถูก = ปลาราคาถูก · แพง = มีโอกาสได้ปลาราคาแพง
--      ไส้เดือน 15 · หนอนแดง 30 (Lv3) · กุ้งฝอย 70 (Lv8) · เหยื่อทอง 180 (Lv15)
--  • ผู้เล่นทุกคนได้ไส้เดือนฟรี 10 ชิ้น (ครั้งเดียว) · ผู้เล่นใหม่เริ่มต้นมีไส้เดือน 10 ชิ้น
--  • ปลาทองประจำวัน 🐠✨: วันละ 1 ตัวทั้งบริษัท ใครตกได้ก่อนได้ไป
--      ขายได้ 2,500 เหรียญ หรือใช้แทนเหรียญ+วัตถุดิบในการขยายยุ้งฉาง/พื้นที่ของแต่ง 1 ครั้ง
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := jsonb_set(c, '{baits}', '{
    "worm":{"n":"ไส้เดือน","e":"🐛","cost":15,"lv":1,"w":[72,22,5,1,0],"note":"ส่วนใหญ่ได้ปลาธรรมดา"},
    "redworm":{"n":"หนอนแดง","e":"🦟","cost":30,"lv":3,"w":[50,32,14,3.5,0.5],"note":"ได้ปลาไม่ธรรมดาบ่อยขึ้น"},
    "shrimpbait":{"n":"กุ้งฝอย","e":"🦐","cost":70,"lv":8,"w":[28,34,26,10,2],"note":"มีโอกาสได้ปลาหายาก"},
    "goldbait":{"n":"เหยื่อทอง","e":"🌟","cost":180,"lv":15,"w":[10,22,34,24,10],"note":"โอกาสปลาหายากมาก/ตำนานสูงสุด"}}'::jsonb);
  c := jsonb_set(c, '{fish,f_goldday}', '{"n":"ปลาทองประจำวัน","e":"🐠","hue":0,"r":5,"w":[1.0,3.0],"sell":2500,"xp":100,"daily":true}'::jsonb);
  c := jsonb_set(c, '{products,f_goldday}', '{"n":"ปลาทองประจำวัน","e":"🐠","sell":2500,"fish":true}'::jsonb);
  c := c || '{"fish_free":0,"fish_need_bait":true,"fish_gold_chance":0.012}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

alter table public.fish_profile alter column bait set default '{"worm":10}'::jsonb;
alter table public.fish_profile add column if not exists starter boolean not null default false;
update public.fish_profile set bait = jsonb_set(coalesce(bait, '{}'::jsonb), '{worm}', to_jsonb(coalesce((bait->>'worm')::int, 0) + 10)), starter = true where not starter;
alter table public.fish_profile alter column starter set default true;

create table if not exists public.fish_gold (
  day       date primary key,
  winner_id uuid references public.employees(id) on delete set null,
  catch_id  bigint,
  weight    numeric,
  at        timestamptz not null default now()
);
alter table public.fish_gold enable row level security;
revoke all on public.fish_gold from anon, public, authenticated;

create or replace function public.fish_gold_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('day', public.farm_today(), 'caught', g.day is not null,
    'by', coalesce(nullif(e.display_name, ''), e.employee_no), 'by_id', g.winner_id, 'weight', g.weight, 'at', g.at)
    from (select 1) z left join fish_gold g on g.day = public.farm_today() left join employees e on e.id = g.winner_id
$$;

create or replace function public.fish_info() returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me(); p fish_profile; c jsonb := public.farm_cat(); fl int; wk int; rk int;
begin
  select * into p from fish_profile where employee_id = e;
  fl := (c->>'fish_free')::int - case when p.free_day = public.farm_today() then p.free_used else 0 end;
  select coalesce(sum(points), 0) into wk from fish_catches where employee_id = e and status = 'landed' and landed_at >= public.fish_week_start();
  select count(*) + 1 into rk from (select employee_id, sum(points) s from fish_catches where status = 'landed' and landed_at >= public.fish_week_start() group by 1) z where z.s > wk;
  return jsonb_build_object('rod', p.rod, 'bait', p.bait, 'free_left', 0, 'free_unlimited', false, 'need_bait', true, 'gold', public.fish_gold_status(), 'coins', public.farm_coins(e),
    'level', (select public.farm_level(xp) from farm_profile where employee_id = e),
    'week_points', wk, 'week_rank', case when wk > 0 then rk end,
    'book', coalesce((select jsonb_object_agg(fish, jsonb_build_object('n', n, 'best', best)) from (
        select fish, count(*) n, max(weight) best from fish_catches where employee_id = e and status = 'landed' group by fish) b), '{}'));
end $$;

create or replace function public.fish_cast(p_bait text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me(); c jsonb := public.farm_cat(); p fish_profile; b jsonb; w numeric[]; tot numeric := 0; x numeric; r int := 1; i int;
  k text; f jsonb; wt numeric; lo numeric; hi numeric; pts int; nid bigint; gch numeric;
begin
  select * into p from fish_profile where employee_id = e for update;
  if p.last_cast > now() - interval '3 seconds' then raise exception 'ใจเย็น ๆ รอปลาสักครู่'; end if;
  if coalesce(p_bait, '') = '' then raise exception 'ต้องใช้เหยื่อทุกครั้ง — เลือกเหยื่อ หรือซื้อที่ 🛒 ร้านอุปกรณ์'; end if;
  b := c->'baits'->p_bait;
  if b is null then raise exception 'ไม่มีเหยื่อนี้'; end if;
  if coalesce((p.bait->>p_bait)::int, 0) < 1 then raise exception 'เหยื่อ% หมดแล้ว — ซื้อเพิ่มที่ 🛒 ร้านอุปกรณ์', b->>'n'; end if;
  update fish_catches set status = 'lost' where employee_id = e and status = 'hook';
  update fish_profile set bait = jsonb_set(bait, array[p_bait], to_jsonb((bait->>p_bait)::int - 1)), last_cast = now() where employee_id = e;
  -- โอกาสแต่ละระดับมาจากเหยื่อ · เบ็ดดีช่วยเพิ่มโอกาสปลาหายาก
  w := array[(b->'w'->>0)::numeric, (b->'w'->>1)::numeric, (b->'w'->>2)::numeric, (b->'w'->>3)::numeric, (b->'w'->>4)::numeric];
  for i in 2..5 loop w[i] := w[i] * (1 + 0.12 * (p.rod - 1)) * case when i >= 3 then 1 + 0.25 * (p.rod - 1) else 1 end; end loop;
  for i in 1..5 loop tot := tot + w[i]; end loop;
  x := random() * tot;
  for i in 1..5 loop if x < w[i] then r := i; exit; end if; x := x - w[i]; end loop;
  -- ปลาทองประจำวัน (ยังไม่มีใครตกได้วันนี้)
  gch := coalesce((c->>'fish_gold_chance')::numeric, 0.012) * case p_bait when 'goldbait' then 3 when 'shrimpbait' then 1.8 when 'redworm' then 1.3 else 1 end * (1 + 0.1 * (p.rod - 1));
  if not exists (select 1 from fish_gold where day = public.farm_today()) and random() < gch then
    k := 'f_goldday'; r := 5;
  else
    select key into k from jsonb_each(c->'fish') where (value->>'r')::int = r and not coalesce((value->>'daily')::boolean, false) order by random() limit 1;
  end if;
  f := c->'fish'->k; lo := (f->'w'->>0)::numeric; hi := (f->'w'->>1)::numeric;
  wt := round((lo + (hi - lo) * power(random(), greatest(0.6, 1.7 - 0.12 * p.rod)))::numeric, 2);
  pts := case when k = 'f_goldday' then 150 else round(((c->'fish_pts'->>(r - 1))::int * (1 + (wt - lo) / nullif(hi - lo, 0)))::numeric) end;
  insert into fish_catches (employee_id, fish, weight, points) values (e, k, wt, coalesce(pts, 1)) returning id into nid;
  return jsonb_build_object('id', nid, 'r', r, 'zone', (c->'rods'->(p.rod::text)->>'zone')::numeric, 'gold', k = 'f_goldday');
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
  return jsonb_build_object('ok', true, 'fish', x.fish, 'r', (f->>'r')::int, 'weight', x.weight, 'points', x.points, 'xp', (f->>'xp')::int,
    'new_best', best is null or x.weight > best, 'first', best is null, 'record', rec, 'gold', gold);
end $$;

-- ใช้ปลาทองประจำวัน 1 ตัว แทนเหรียญ+วัตถุดิบ ในการขยายยุ้งฉาง / พื้นที่ของแต่ง
create or replace function public.farm_upgrade_gold(p_kind text) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); have int;
begin
  if p_kind not in ('barn', 'decor') then raise exception 'ไม่รู้จักการขยายนี้'; end if;
  perform 1 from farm_profile where employee_id = e for update;
  select qty into have from farm_items where employee_id = e and item = 'f_goldday' for update;
  if coalesce(have, 0) < 1 then raise exception 'ไม่มีปลาทองประจำวัน — ไปตกที่ทะเลสาบก่อนนะ'; end if;
  update farm_items set qty = qty - 1 where employee_id = e and item = 'f_goldday';
  insert into farm_ledger (employee_id, delta, reason) values (e, 0, 'ใช้ปลาทองประจำวันขยาย' || case when p_kind = 'barn' then 'ยุ้งฉาง' else 'พื้นที่ของแต่ง' end);
  if p_kind = 'barn' then
    update farm_profile set barn_lv = barn_lv + 1 where employee_id = e;
    perform public.farm_add_xp(e, 5);
    return public.farm_barn_cap(e);
  end if;
  update farm_profile set decor_lv = decor_lv + 1 where employee_id = e;
  perform public.farm_add_xp(e, 5);
  return public.farm_decor_cap(e);
end $$;

revoke execute on function public.fish_gold_status(), public.farm_upgrade_gold(text) from public, anon;
grant execute on function public.fish_gold_status(), public.farm_upgrade_gold(text) to authenticated;
notify pgrst, 'reload schema';
