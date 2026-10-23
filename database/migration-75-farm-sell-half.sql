-- อัปเดต 152: ขายด่วนครึ่งราคา + วางของแต่งได้ทั่วเขตฟาร์ม
--   farm_sell_half(item, qty)  : ขายผลผลิตจากยุ้งฉางให้ระบบได้ครึ่งราคา (ราคาปกติ × จำนวน ÷ 2)
--   farm_stall_sell_half(id)   : ของที่วางในร้านริมทางแล้วยังขายไม่ได้ (รวมของเน่า) กดขายให้ระบบครึ่งราคา
create or replace function public.farm_sell_half(p_item text, p_qty int) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); amt int; half int;
begin
  if p_qty is null or p_qty < 1 then raise exception 'จำนวนไม่ถูกต้อง'; end if;
  amt := public.farm_sell_core(p_item, p_qty);
  half := greatest(1, amt / 2);
  if amt - half > 0 then
    insert into farm_ledger (employee_id, delta, reason) values (e, half - amt, 'ขายด่วนครึ่งราคา (ส่วนลด 50%)');
  end if;
  return half;
end $$;

create or replace function public.farm_stall_sell_half(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); s farm_stall;
begin
  select * into s from farm_stall where id = p_id and seller_id = e for update;
  if not found then raise exception 'ไม่พบรายการ'; end if;
  if s.buyer_id is not null then raise exception 'ขายไปแล้ว — กดเก็บเงินแทน'; end if;
  delete from farm_stall where id = p_id;
  perform public.farm_add_item(e, s.item, s.qty);
  return public.farm_sell_half(s.item, s.qty);
end $$;

-- ย้ายของแต่งได้ทุกช่องในเขตฟาร์ม (x -1..15, y -1..12) รวมที่ว่างหลังย้ายยุ้งฉาง/บ้าน และหน้ากังหันลม
create or replace function public.farm_move_decor(p_id uuid, p_x int, p_y int, p_ox int default null, p_oy int default null) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); d farm_decor; o farm_decor; okp boolean;
begin
  select * into d from farm_decor where id = p_id and employee_id = e and not stored for update;
  if not found then raise exception 'ไม่พบของแต่งชิ้นนี้'; end if;
  okp := exists (select 1 from farm_parcels f, public.farm_parcel_def(f.pid) x where f.employee_id = e and f.use = 'decor'
          and p_x >= (x->>'x')::numeric and p_x < (x->>'x')::numeric + (x->>'w')::int and p_y >= (x->>'y')::numeric and p_y < (x->>'y')::numeric + (x->>'h')::int);
  if not okp and (p_x < -1 or p_x > 15 or p_y < -1 or p_y > 12) then raise exception 'วางนอกฟาร์มไม่ได้'; end if;
  select * into o from farm_decor where employee_id = e and gx = p_x and gy = p_y and id <> p_id and not stored limit 1;
  if found then update farm_decor set gx = coalesce(d.gx, p_ox), gy = coalesce(d.gy, p_oy) where id = o.id; end if;
  update farm_decor set gx = p_x, gy = p_y where id = p_id;
end $$;

revoke execute on function public.farm_sell_half(text, int), public.farm_stall_sell_half(bigint) from public, anon;
grant execute on function public.farm_sell_half(text, int), public.farm_stall_sell_half(bigint) to authenticated;
notify pgrst, 'reload schema';
