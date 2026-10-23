-- อัปเดต 151: ผู้เล่นใหม่ที่เข้าเกมฟาร์มครั้งแรก ได้เหรียญเริ่มต้นรวม 5,000 เหรียญ
-- (เหรียญ = start_coins + KPI + ledger → เพิ่ม ledger ส่วนต่างให้ครบ 5,000 ตอนสร้าง farm_profile)
create or replace function public.farm_welcome_bonus() returns trigger
language plpgsql security definer set search_path = public as $$
declare amt int := 5000 - coalesce((public.farm_cat()->>'start_coins')::int, 0);
begin
  if amt > 0 and not exists (select 1 from farm_ledger where employee_id = new.employee_id and reason = 'โบนัสผู้เล่นใหม่') then
    insert into farm_ledger (employee_id, delta, reason) values (new.employee_id, amt, 'โบนัสผู้เล่นใหม่');
  end if;
  return new;
end $$;
revoke execute on function public.farm_welcome_bonus() from public, anon, authenticated;
drop trigger if exists farm_profile_welcome on public.farm_profile;
create trigger farm_profile_welcome after insert on public.farm_profile
  for each row execute function public.farm_welcome_bonus();
notify pgrst, 'reload schema';
