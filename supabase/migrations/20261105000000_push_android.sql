-- Android phones keep their Firebase Cloud Messaging token here too, next to iPhones' APNs tokens.
alter table public.push_tokens drop constraint if exists push_tokens_platform_check;
alter table public.push_tokens add constraint push_tokens_platform_check check (platform in ('ios', 'android'));
