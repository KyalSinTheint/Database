-- Sync accounts: every login account (auth.users) gets a role and can log in.
-- Safe to run any time, as often as you like.

-- 1) Every account has a role row (new ones become 'user'; existing roles are kept)
insert into public.app_users (user_id, email, role)
select u.id, lower(u.email), 'user'
from auth.users u
where not exists (select 1 from public.app_users a where a.user_id = u.id);

-- 2) Emails in app_users match the login emails
update public.app_users a
set email = lower(u.email)
from auth.users u
where u.id = a.user_id and a.email is distinct from lower(u.email);

-- 3) Accounts added by SQL can log in: confirm the email and fill empty token fields
update auth.users
set email_confirmed_at     = coalesce(email_confirmed_at, now()),
    confirmation_token     = coalesce(confirmation_token, ''),
    recovery_token         = coalesce(recovery_token, ''),
    email_change           = coalesce(email_change, ''),
    email_change_token_new = coalesce(email_change_token_new, '')
where email_confirmed_at is null
   or confirmation_token is null or recovery_token is null
   or email_change is null or email_change_token_new is null;

-- 4) Every account has an email login identity
insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, 'email',
       jsonb_build_object('sub', u.id::text, 'email', lower(u.email), 'email_verified', true),
       now(), now(), now()
from auth.users u
where not exists (select 1 from auth.identities i where i.user_id = u.id and i.provider = 'email');

-- 5) Result
select u.email,
       a.role,
       u.email_confirmed_at is not null                                         as can_log_in,
       exists (select 1 from auth.identities i where i.user_id = u.id)          as has_identity,
       u.created_at,
       u.last_sign_in_at
from auth.users u
left join public.app_users a on a.user_id = u.id
order by a.role, u.email;
