-- Public downloads for the website: the signed Android app (sadhana.apk), linked from the Android "get the app" sheet.
-- Only APK files, up to 80 MB; uploads only with the service role (no upload policy for anyone else).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('downloads', 'downloads', true, 83886080, array['application/vnd.android.package-archive'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
