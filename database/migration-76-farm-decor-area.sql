-- อัปเดต 153: วางของแต่งได้ถึงลานสัตว์เลี้ยงและแนวระหว่างลานกับฟาร์ม (x -8..15, y -1..12)
create or replace function public.farm_move_decor(p_id uuid, p_x int, p_y int, p_ox int default null, p_oy int default null) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); d farm_decor; o farm_decor; okp boolean;
begin
  select * into d from farm_decor where id = p_id and employee_id = e and not stored for update;
  if not found then raise exception 'ไม่พบของแต่งชิ้นนี้'; end if;
  okp := exists (select 1 from farm_parcels f, public.farm_parcel_def(f.pid) x where f.employee_id = e and f.use = 'decor'
          and p_x >= (x->>'x')::numeric and p_x < (x->>'x')::numeric + (x->>'w')::int and p_y >= (x->>'y')::numeric and p_y < (x->>'y')::numeric + (x->>'h')::int);
  if not okp and (p_x < -8 or p_x > 15 or p_y < -1 or p_y > 12) then raise exception 'วางนอกฟาร์มไม่ได้'; end if;
  select * into o from farm_decor where employee_id = e and gx = p_x and gy = p_y and id <> p_id and not stored limit 1;
  if found then update farm_decor set gx = coalesce(d.gx, p_ox), gy = coalesce(d.gy, p_oy) where id = o.id; end if;
  update farm_decor set gx = p_x, gy = p_y where id = p_id;
end $$;
notify pgrst, 'reload schema';
