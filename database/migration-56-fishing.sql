-- =====================================================================
-- Migration 56: ทะเลสาบตกปลา 🎣
--  • ปลา 20 ชนิด 5 ระดับ (ธรรมดา → ตำนาน) · น้ำหนักสุ่ม · ได้คะแนนตามความหายาก×น้ำหนัก
--  • ร้านอุปกรณ์: เบ็ด 5 ระดับ (ปลดตามเลเวล) + เหยื่อ 4 แบบ · เหวี่ยงฟรีวันละ 15 ครั้ง
--  • ระบบสุ่มปลาอยู่ฝั่งเซิร์ฟเวอร์ (โกงไม่ได้) · ปลาที่ได้เข้ายุ้งฉาง ขาย/ตั้งร้านได้
--  • จัดอันดับรายสัปดาห์ / ตลอดกาล · สถิติปลาตัวใหญ่สุด · เห็นเพื่อนที่กำลังตกปลาอยู่
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); f jsonb; k text; begin
  f := '{
   "f_boot":      {"n":"รองเท้าบูตเก่า","e":"🥾","hue":0,  "r":1,"w":[0.3,1.2], "sell":2,  "xp":1},
   "f_tilapia":   {"n":"ปลานิล",        "e":"🐟","hue":0,  "r":1,"w":[0.2,1.5], "sell":10, "xp":1},
   "f_barb":      {"n":"ปลาตะเพียน",    "e":"🐟","hue":40, "r":1,"w":[0.2,1.2], "sell":9,  "xp":1},
   "f_catfish":   {"n":"ปลาดุก",        "e":"🐟","hue":200,"r":1,"w":[0.3,2.0], "sell":12, "xp":1},
   "f_perch":     {"n":"ปลาหมอ",        "e":"🐠","hue":0,  "r":1,"w":[0.1,0.6], "sell":8,  "xp":1},
   "f_snakehead": {"n":"ปลาช่อน",       "e":"🐟","hue":260,"r":2,"w":[0.5,3.5], "sell":30, "xp":3},
   "f_gourami":   {"n":"ปลาสลิด",       "e":"🐠","hue":120,"r":2,"w":[0.1,0.5], "sell":26, "xp":3},
   "f_carp":      {"n":"ปลายี่สก",      "e":"🐟","hue":80, "r":2,"w":[1.0,6.0], "sell":38, "xp":3},
   "f_knife":     {"n":"ปลากราย",       "e":"🐟","hue":300,"r":2,"w":[0.5,4.0], "sell":34, "xp":3},
   "f_giantsnake":{"n":"ปลาชะโด",       "e":"🐟","hue":330,"r":3,"w":[2.0,12.0],"sell":85, "xp":8},
   "f_pangasius": {"n":"ปลาเทพา",       "e":"🐋","hue":180,"r":3,"w":[5.0,40.0],"sell":110,"xp":8},
   "f_goby":      {"n":"ปลาบู่",        "e":"🐡","hue":30, "r":3,"w":[0.3,2.5], "sell":75, "xp":8},
   "f_softshell": {"n":"ตะพาบน้ำ",      "e":"🐢","hue":0,  "r":3,"w":[1.0,8.0], "sell":95, "xp":8},
   "f_stingray":  {"n":"กระเบนน้ำจืด",  "e":"🦈","hue":20, "r":4,"w":[10,80],   "sell":260,"xp":20},
   "f_tigerperch":{"n":"ปลาเสือตอ",     "e":"🐠","hue":45, "r":4,"w":[0.5,3.0], "sell":300,"xp":20},
   "f_arowana":   {"n":"ปลาอะโรวาน่า",  "e":"🐉","hue":0,  "r":4,"w":[1.0,6.0], "sell":340,"xp":20},
   "f_shrimp":    {"n":"กุ้งก้ามกรามยักษ์","e":"🦞","hue":200,"r":4,"w":[0.3,1.5],"sell":220,"xp":20},
   "f_mekong":    {"n":"ปลาบึก",        "e":"🐋","hue":220,"r":5,"w":[80,300],  "sell":900,"xp":50},
   "f_giantcarp": {"n":"ปลากระโห้",     "e":"🐟","hue":15, "r":5,"w":[30,150],  "sell":750,"xp":50},
   "f_golden":    {"n":"ปลาทองคำนำโชค", "e":"🐠","hue":0,  "r":5,"w":[0.5,2.0], "sell":1200,"xp":60}
  }'::jsonb;
  c := jsonb_set(c, '{fish}', f);
  -- ใส่ปลาเป็นสินค้า (ขายในยุ้ง/ตั้งร้านได้)
  for k in select jsonb_object_keys(f) loop
    c := jsonb_set(c, array['products', k], jsonb_build_object('n', f->k->>'n', 'e', f->k->>'e', 'sell', (f->k->>'sell')::int, 'fish', true));
  end loop;
  c := c || '{
   "rods":{"1":{"n":"เบ็ดไม้ไผ่","e":"🎋","cost":0,"lv":1,"zone":0.30},
           "2":{"n":"เบ็ดไฟเบอร์","e":"🎣","cost":600,"lv":5,"zone":0.34},
           "3":{"n":"เบ็ดคาร์บอน","e":"🎣","cost":2000,"lv":12,"zone":0.38},
           "4":{"n":"เบ็ดทองคำ","e":"✨","cost":6000,"lv":20,"zone":0.42},
           "5":{"n":"เบ็ดตำนานเจ้าบึง","e":"🔱","cost":15000,"lv":30,"zone":0.46}},
   "baits":{"worm":{"n":"ไส้เดือน","e":"🪱","cost":5,"lv":1,"boost":1.15,"min_r":2},
            "redworm":{"n":"หนอนแดง","e":"🐛","cost":15,"lv":3,"boost":1.5,"min_r":2},
            "shrimpbait":{"n":"กุ้งฝอย","e":"🦐","cost":40,"lv":8,"boost":2.0,"min_r":3},
            "goldbait":{"n":"เหยื่อทอง","e":"🌟","cost":150,"lv":15,"boost":3.0,"min_r":4}},
   "fish_free":15,"fish_pts":[1,3,8,20,50]}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

create table if not exists public.fish_profile (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  rod         int  not null default 1,
  bait        jsonb not null default '{}',
  free_day    date,
  free_used   int  not null default 0,
  last_cast   timestamptz,
  avatar      text,
  here_at     timestamptz
);
create table if not exists public.fish_catches (
  id          bigserial primary key,
  employee_id uuid not null references public.employees(id) on delete cascade,
  fish        text not null,
  weight      numeric(7,2) not null,
  points      int  not null default 0,
  status      text not null default 'hook' check (status in ('hook','landed','lost')),
  created_at  timestamptz not null default now(),
  landed_at   timestamptz
);
create index if not exists fish_catches_landed_idx on public.fish_catches (landed_at desc) where status = 'landed';
create index if not exists fish_catches_emp_idx on public.fish_catches (employee_id, status);
alter table public.fish_profile enable row level security;
alter table public.fish_catches enable row level security;
revoke all on public.fish_profile, public.fish_catches from anon, public, authenticated;

create or replace function public.fish_me() returns uuid
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me();
begin
  insert into fish_profile (employee_id) values (e) on conflict do nothing;
  return e;
end $$;

create or replace function public.fish_week_start() returns timestamptz language sql stable as $$
  select (date_trunc('week', now() at time zone 'Asia/Bangkok')) at time zone 'Asia/Bangkok'
$$;

create or replace function public.fish_info() returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me(); p fish_profile; c jsonb := public.farm_cat(); fl int; wk int; rk int;
begin
  select * into p from fish_profile where employee_id = e;
  fl := (c->>'fish_free')::int - case when p.free_day = public.farm_today() then p.free_used else 0 end;
  select coalesce(sum(points), 0) into wk from fish_catches where employee_id = e and status = 'landed' and landed_at >= public.fish_week_start();
  select count(*) + 1 into rk from (select employee_id, sum(points) s from fish_catches where status = 'landed' and landed_at >= public.fish_week_start() group by 1) z where z.s > wk;
  return jsonb_build_object('rod', p.rod, 'bait', p.bait, 'free_left', greatest(fl, 0), 'coins', public.farm_coins(e),
    'level', (select public.farm_level(xp) from farm_profile where employee_id = e),
    'week_points', wk, 'week_rank', case when wk > 0 then rk end,
    'book', coalesce((select jsonb_object_agg(fish, jsonb_build_object('n', n, 'best', best)) from (
        select fish, count(*) n, max(weight) best from fish_catches where employee_id = e and status = 'landed' group by fish) b), '{}'));
end $$;

create or replace function public.fish_buy(p_kind text, p_key text, p_qty int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me(); c jsonb := public.farm_cat(); o jsonb; lv int; p fish_profile; q int := greatest(1, least(coalesce(p_qty, 1), 99));
begin
  select public.farm_level(xp) into lv from farm_profile where employee_id = e;
  select * into p from fish_profile where employee_id = e for update;
  if p_kind = 'rod' then
    o := c->'rods'->p_key;
    if o is null then raise exception 'ไม่มีเบ็ดนี้'; end if;
    if p_key::int <= p.rod then raise exception 'มีเบ็ดที่ดีกว่าหรือเท่ากันแล้ว'; end if;
    if not public.is_admin() and lv < (o->>'lv')::int then raise exception 'ต้องเลเวล % ก่อน', o->>'lv'; end if;
    perform public.farm_spend(e, (o->>'cost')::int, 'ซื้อ' || (o->>'n'));
    update fish_profile set rod = p_key::int where employee_id = e;
  elsif p_kind = 'bait' then
    o := c->'baits'->p_key;
    if o is null then raise exception 'ไม่มีเหยื่อนี้'; end if;
    if not public.is_admin() and lv < (o->>'lv')::int then raise exception 'ต้องเลเวล % ก่อน', o->>'lv'; end if;
    perform public.farm_spend(e, (o->>'cost')::int * q, 'ซื้อเหยื่อ' || (o->>'n') || ' ×' || q);
    update fish_profile set bait = jsonb_set(bait, array[p_key], to_jsonb(coalesce((bait->>p_key)::int, 0) + q)) where employee_id = e;
  else raise exception 'ไม่ถูกต้อง'; end if;
  return public.fish_info();
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
    if p.free_day = public.farm_today() and p.free_used >= (c->>'fish_free')::int then raise exception 'เหวี่ยงฟรีวันนี้หมดแล้ว — ซื้อเหยื่อที่ร้านอุปกรณ์'; end if;
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

create or replace function public.fish_land(p_id bigint, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me(); x fish_catches; c jsonb := public.farm_cat(); f jsonb; best numeric; rec boolean;
begin
  select * into x from fish_catches where id = p_id and employee_id = e for update;
  if not found or x.status <> 'hook' then raise exception 'ปลาหลุดไปแล้ว'; end if;
  if x.created_at < now() - interval '90 seconds' then update fish_catches set status = 'lost' where id = p_id; raise exception 'ปลาหลุดไปแล้ว'; end if;
  f := c->'fish'->x.fish;
  if not p_ok then
    update fish_catches set status = 'lost' where id = p_id;
    return jsonb_build_object('ok', false, 'fish', x.fish, 'r', (f->>'r')::int);
  end if;
  if public.farm_barn_used(e) >= public.farm_barn_cap(e) then raise exception 'ยุ้งฉางเต็ม — ขายของก่อนแล้วค่อยตกต่อ'; end if;
  select max(weight) into best from fish_catches where employee_id = e and fish = x.fish and status = 'landed';
  select x.weight > coalesce(max(weight), 0) into rec from fish_catches where fish = x.fish and status = 'landed';
  update fish_catches set status = 'landed', landed_at = now() where id = p_id;
  perform public.farm_add_item(e, x.fish, 1);
  perform public.farm_add_xp(e, (f->>'xp')::int);
  return jsonb_build_object('ok', true, 'fish', x.fish, 'r', (f->>'r')::int, 'weight', x.weight, 'points', x.points, 'xp', (f->>'xp')::int,
    'new_best', best is null or x.weight > best, 'first', best is null, 'record', rec);
end $$;

create or replace function public.fish_board(p_scope text default 'week') returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.my_employee_id() is null then '[]'::jsonb else coalesce((select jsonb_agg(z order by z.points desc, z.catches desc) from (
    select c.employee_id id, coalesce(nullif(e.display_name, ''), e.employee_no) name, e.avatar, fp.avatar body,
           sum(c.points)::int points, count(*)::int catches,
           (select jsonb_build_object('fish', b.fish, 'weight', b.weight) from fish_catches b where b.employee_id = c.employee_id and b.status = 'landed'
              and (p_scope <> 'week' or b.landed_at >= public.fish_week_start()) order by b.points desc, b.weight desc limit 1) best
      from fish_catches c join employees e on e.id = c.employee_id left join fish_profile fp on fp.employee_id = c.employee_id
     where c.status = 'landed' and (p_scope <> 'week' or c.landed_at >= public.fish_week_start())
     group by c.employee_id, e.display_name, e.employee_no, e.avatar, fp.avatar
     order by sum(c.points) desc limit 30) z), '[]'::jsonb) end
$$;

create or replace function public.fish_records() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.my_employee_id() is null then '{}'::jsonb else coalesce((select jsonb_object_agg(fish, jsonb_build_object('weight', weight, 'name', name)) from (
    select distinct on (c.fish) c.fish, c.weight, coalesce(nullif(e.display_name, ''), e.employee_no) name
      from fish_catches c join employees e on e.id = c.employee_id where c.status = 'landed' order by c.fish, c.weight desc) r), '{}'::jsonb) end
$$;

create or replace function public.fish_presence(p_avatar text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me();
begin
  update fish_profile set here_at = now(), avatar = coalesce(left(p_avatar, 20), avatar) where employee_id = e;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.employee_id, 'name', coalesce(nullif(x.display_name, ''), x.employee_no), 'body', p.avatar, 'admin', x.role = 'admin',
      'last', (select jsonb_build_object('fish', c.fish, 'weight', c.weight, 'at', c.landed_at) from fish_catches c where c.employee_id = p.employee_id and c.status = 'landed' and c.landed_at > now() - interval '2 minutes' order by c.landed_at desc limit 1))
      order by p.here_at desc)
    from fish_profile p join employees x on x.id = p.employee_id
    where p.employee_id <> e and p.here_at > now() - interval '2 minutes' limit 12), '[]'::jsonb);
end $$;

create or replace function public.fish_leave() returns void
language sql security definer set search_path = public as $$
  update fish_profile set here_at = null where employee_id = public.my_employee_id()
$$;

revoke execute on function public.fish_me(), public.fish_week_start() from public, anon, authenticated;
revoke execute on function public.fish_info(), public.fish_buy(text, text, int), public.fish_cast(text), public.fish_land(bigint, boolean),
  public.fish_board(text), public.fish_records(), public.fish_presence(text), public.fish_leave() from public, anon;
grant execute on function public.fish_info(), public.fish_buy(text, text, int), public.fish_cast(text), public.fish_land(bigint, boolean),
  public.fish_board(text), public.fish_records(), public.fish_presence(text), public.fish_leave() to authenticated;
notify pgrst, 'reload schema';
