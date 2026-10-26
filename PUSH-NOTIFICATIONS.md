# Push notifications — setup and test

The code is written. What's left needs your Apple account and your go-ahead for the live server.

## 1. Apple: make a push key (2 min)
1. developer.apple.com → **Certificates, Identifiers & Profiles** → **Keys** → **+**.
2. Name it "Sadhana push", tick **Apple Push Notifications service (APNs)** → Continue → Register.
3. **Download** the `.p8` file (only possible once — keep it safe) and note the **Key ID** (10 characters).
4. Your **Team ID** is `3B5P8HQ7M7`.
5. **Identifiers** → `online.vanarsathi.app` → make sure **Push Notifications** is ticked → Save.

## 2. Supabase: secrets, table, function
Run in Terminal (in `~/Developer/naam-jaap-sadhna`), with your own values:
```
supabase secrets set --project-ref brtlirkvtkocdxginvlj \
  APNS_KEY_ID=YOURKEYID APNS_TEAM_ID=3B5P8HQ7M7 \
  APNS_KEY_P8="$(cat ~/Downloads/AuthKey_YOURKEYID.p8)" \
  PUSH_SECRET="$(openssl rand -hex 24 | tee ~/sadhana-push-secret.txt)"
supabase db query --linked -f supabase/migrations/20261103000000_push_tokens.sql
supabase migration repair --status applied 20261103000000 --linked
supabase functions deploy send-push --project-ref brtlirkvtkocdxginvlj --use-api --no-verify-jwt
```
`~/sadhana-push-secret.txt` now holds the secret that lets you send. Don't share it.

## 3. New iPhone build (Claude can do this — just ask "build with push")
The app needs the push permission in a new TestFlight build (build 14). Code is ready in both repos (not pushed).

## 4. Test
1. Install build 14 from TestFlight, open it. Notifications must be allowed (Settings → turn on "Daily jaap reminder" if you were never asked).
2. Check your phone registered:
   `supabase db query --linked "select user_id, updated_at from public.push_tokens"` → one row.
3. Close the app, lock the phone, then send:
   `PUSH_SECRET=$(cat ~/sadhana-push-secret.txt) tools/send-push.sh "🙏 Test" "Push works"`
   You should see `{"phones":1,"sent":1,...}` and the notification on the phone within seconds.
4. If `sent` is 0, the reply's `reasons` says why:
   - `InvalidProviderToken` → wrong Key ID / Team ID / .p8
   - `BadDeviceToken` → build made without the push permission
   - `DeviceTokenNotForTopic` → bundle ID mismatch

## Later
Send to everyone with the same command (no user id). For one person add their user id as the third argument.
