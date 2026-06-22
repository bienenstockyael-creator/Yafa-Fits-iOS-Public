-- Stop seeding display_name from the email local-part on signup.
--
-- handle_new_user() previously fell back to
-- split_part(new.email, '@', 1) when the signup carried no
-- display_name in its metadata. For email / email-OTP signups that
-- meant every new profile landed with a junk display_name like
-- "yael.bienenstock" (the part before the @). The onboarding flow
-- then pre-filled the "What's your full name?" field with that junk,
-- hiding the prompt.
--
-- Sign in with Apple still passes a real name via
-- raw_user_meta_data->>'display_name', so that path is preserved.
-- Email signups now get a NULL display_name, and the onboarding name
-- step starts empty — showing the prompt as intended.
--
-- `create or replace function` keeps the existing
-- on_auth_user_created trigger binding intact (it references this
-- function by name), so no trigger recreation is needed.
create or replace function public.handle_new_user()
returns trigger as $func$
begin
  insert into public.profiles (id, display_name)
  values (new.id, nullif(new.raw_user_meta_data ->> 'display_name', ''));
  return new;
end;
$func$ language plpgsql security definer;
