-- =====================================================================
-- Migration 58: ทะเลสาบตกปลา — เหวี่ยงเบ็ดได้ไม่จำกัด
--  • ไม่ใช้เหยื่อ = เหวี่ยงฟรีได้ไม่จำกัดครั้ง (fish_free = 0 หมายถึงไม่จำกัด)
--  • เหยื่อยังใช้ได้ตามเดิม (ช่วยให้เจอปลาหายาก) — เหยื่อหมดก็เหวี่ยงแบบไม่ใช้เหยื่อต่อได้
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := c || '{"fish_free":0}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

create or replace function public.fish_info() returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me(); p fish_profile; c jsonb := public.farm_cat(); fl int; wk int; rk int;
begin
  select * into p from fish_profile where employee_id = e;
  fl := (c->>'fish_free')::int - case when p.free_day = public.farm_today() then p.free_used else 0 end;
  select coalesce(sum(points), 0) into wk from fish_catches where employee_id = e and status = 'landed' and landed_at >= public.fish_week_start();
  select count(*) + 1 into rk from (select employee_id, sum(points) s from fish_catches where status = 'landed' and landed_at >= public.fish_week_start() group by 1) z where z.s > wk;
  return jsonb_build_object('rod', p.rod, 'bait', p.bait, 'free_left', case when (c->>'fish_free')::int > 0 then greatest(fl, 0) end, 'free_unlimited', (c->>'fish_free')::int <= 0, 'coins', public.farm_coins(e),
    'level', (select public.farm_level(xp) from farm_profile where employee_id = e),
    'week_points', wk, 'week_rank', case when wk > 0 then rk end,
    'book', coalesce((select jsonb_object_agg(fish, jsonb_build_object('n', n, 'best', best)) from (
        select fish, count(*) n, max(weight) best from fish_catches where employee_id = e and status = 'landed' group by fish) b), '{}'));
end $$;

create or replace function public.fish_cast(p_bait text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me(); c jsonb := public.farm_cat(); p fish_profile; b jsonb; w numeric[] := array[60,25,10,4,1]; tot numeric := 0; x numeric; r int := 1; i int;
  k text; f jsonb; wt numeric; lo numeric; hi numeric; pts int; nid bigint;
begin
  select * into p from fish_profile where employee_id = e for update;
  if p.last_cast > now() - interval '3 seconds' then raise exception 'ใจเย็น ๆ รอปลาสักครู่'; end if;
  update fish_catches set status = 'lost' where employee_id = e and status = 'hook';
  if coalesce(p_bait, '') = '' then
    if (c->>'fish_free')::int > 0 and p.free_day = public.farm_today() and p.free_used >= (c->>'fish_free')::int then raise exception 'เหวี่ยงฟรีวันนี้หมดแล้ว — ซื้อเหยื่อที่ร้านอุปกรณ์'; end if;
    update fish_profile set free_used = case when free_day = public.farm_today() then free_used + 1 else 1 end, free_day = public.farm_today() where employee_id = e;
  else
    b := c->'baits'->p_bait;
    if b is null then raise exception 'ไม่มีเหยื่อนี้'; end if;
    if coalesce((p.bait->>p_bait)::int, 0) < 1 then raise exception 'เหยื่อ% หมดแล้ว', b->>'n'; end if;
    update fish_profile set bait = jsonb_set(bait, array[p_bait], to_jsonb((bait->>p_bait)::int - 1)) where employee_id = e;
  end if;
  update fish_profile set last_cast = now() where employee_id = e;
  -- ความน่าจะเป็นตามเบ็ดและเหยื่อ
  for i in 2..5 loop w[i] := w[i] * (1 + 0.15 * (p.rod - 1)) * case when i >= 3 then 1 + 0.35 * (p.rod - 1) else 1 end; end loop;
  if b is not null then for i in ((b->>'min_r')::int)..5 loop w[i] := w[i] * (b->>'boost')::numeric; end loop; end if;
  for i in 1..5 loop tot := tot + w[i]; end loop;
  x := random() * tot;
  for i in 1..5 loop if x < w[i] then r := i; exit; end if; x := x - w[i]; end loop;
  select key into k from jsonb_each(c->'fish') where (value->>'r')::int = r order by random() limit 1;
  f := c->'fish'->k; lo := (f->'w'->>0)::numeric; hi := (f->'w'->>1)::numeric;
  wt := round((lo + (hi - lo) * power(random(), greatest(0.6, 1.7 - 0.12 * p.rod)))::numeric, 2);
  pts := round(((c->'fish_pts'->>(r - 1))::int * (1 + (wt - lo) / nullif(hi - lo, 0)))::numeric);
  insert into fish_catches (employee_id, fish, weight, points) values (e, k, wt, coalesce(pts, 1)) returning id into nid;
  return jsonb_build_object('id', nid, 'r', r, 'zone', (c->'rods'->(p.rod::text)->>'zone')::numeric);
end $$;

notify pgrst, 'reload schema';
