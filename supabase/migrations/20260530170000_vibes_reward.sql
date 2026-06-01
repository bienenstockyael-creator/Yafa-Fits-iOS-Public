-- Reward: every 5 vibes received, the recipient earns one
-- free 3D generation credit. Stacks on top of the monthly
-- free pool — these credits don't reset.
--
-- Implemented as an AFTER INSERT trigger on `vibes` so the
-- award is atomic with the insert and can never be missed.
-- Counts ALL vibes the user has ever received and checks if
-- the total is a multiple of 5. Idempotent: a re-insert
-- (won't happen due to the unique constraint, but defensively)
-- wouldn't double-award because the count check pins on the
-- post-insert total.

create or replace function public.award_vibe_credit_if_milestone()
returns trigger
language plpgsql
security definer
set search_path = public
as $func$
declare
    v_total int;
begin
    select count(*) into v_total
    from public.vibes
    where receiver_id = NEW.receiver_id;

    if v_total > 0 and v_total % 5 = 0 then
        update public.profiles
        set gen_credits_free_balance = gen_credits_free_balance + 1
        where id = NEW.receiver_id;
    end if;

    return NEW;
end;
$func$;

drop trigger if exists trg_award_vibe_credit on public.vibes;
create trigger trg_award_vibe_credit
    after insert on public.vibes
    for each row
    execute function public.award_vibe_credit_if_milestone();
