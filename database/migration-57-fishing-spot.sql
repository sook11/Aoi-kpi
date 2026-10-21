-- =====================================================================
-- Migration 57: ทะเลสาบตกปลา — เดินเปลี่ยนที่ตกปลาได้
--  • เก็บตำแหน่งที่ยืนตกปลาล่าสุด (spot_x, spot_z) ให้เพื่อนเห็นว่าเรายืนตรงไหน
--  • fish_presence รับตำแหน่งเพิ่ม (ไม่ส่งก็ได้ = ใช้ตำแหน่งเดิม) และส่งตำแหน่งเพื่อนกลับมา
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
alter table public.fish_profile add column if not exists spot_x real, add column if not exists spot_z real;

drop function if exists public.fish_presence(text);
create or replace function public.fish_presence(p_avatar text default null, p_x real default null, p_z real default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid := public.fish_me();
begin
  update fish_profile set here_at = now(), avatar = coalesce(left(p_avatar, 20), avatar),
         spot_x = case when p_x is not null and p_z is not null then greatest(-40, least(40, p_x)) else spot_x end,
         spot_z = case when p_x is not null and p_z is not null then greatest(-40, least(40, p_z)) else spot_z end
   where employee_id = e;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.employee_id, 'name', coalesce(nullif(x.display_name, ''), x.employee_no), 'body', p.avatar, 'admin', x.role = 'admin',
      'x', p.spot_x, 'z', p.spot_z,
      'last', (select jsonb_build_object('fish', c.fish, 'weight', c.weight, 'at', c.landed_at) from fish_catches c where c.employee_id = p.employee_id and c.status = 'landed' and c.landed_at > now() - interval '2 minutes' order by c.landed_at desc limit 1))
      order by p.here_at desc)
    from (select * from fish_profile where employee_id <> e and here_at > now() - interval '2 minutes' order by here_at desc limit 12) p
    join employees x on x.id = p.employee_id), '[]'::jsonb);
end $$;

revoke execute on function public.fish_presence(text, real, real) from public, anon;
grant execute on function public.fish_presence(text, real, real) to authenticated;
notify pgrst, 'reload schema';
