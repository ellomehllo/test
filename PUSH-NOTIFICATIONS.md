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
  APNS_KEY_ID=4RTCY47GVF APNS_TEAM_ID=3B5P8HQ7M7 \
  APNS_KEY_P8="$(cat ~/Downloads/AuthKey_4RTCY47GVF.p8)" \
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

---

# Android (Firebase) — your part

## A. Firebase project (5 min)
1. console.firebase.google.com → **Create a project** → name it "Sadhana" → Google Analytics **off** → Create.
2. In the project: **Add app → Android**. Package name: `online.vanarsathi.app` (exactly). App nickname: Sadhana. Skip the SHA-1. **Register app**.
3. **Download `google-services.json`** and put it here: `~/Developer/vanarsathi-android/android/app/google-services.json`.
   Skip the rest of Firebase's wizard (the code is already done).
4. ⚙️ **Project settings → Service accounts → Generate new private key** → downloads a `.json` file. Keep it private.

## B. Give the server the key (Terminal, in ~/Developer/naam-jaap-sadhna)
```
supabase secrets set --project-ref brtlirkvtkocdxginvlj FCM_SERVICE_ACCOUNT="$(cat ~/Downloads/YOUR-FIREBASE-KEY-FILE.json)"
supabase db query --linked -f supabase/migrations/20261105000000_push_android.sql
supabase migration repair --status applied 20261105000000 --linked
supabase functions deploy send-push --project-ref brtlirkvtkocdxginvlj --use-api --no-verify-jwt
```

## C. New Android build — tell Claude "google-services.json is in, build Android"
Claude commits the file (it isn't secret), tags a new version, and publishes the APK to the website download.

## D. Test
1. Install the new APK on an Android phone, open it, allow notifications (turn on Settings → Daily jaap reminder).
2. Close the app. Send the same command as for iPhone:
   `PUSH_SECRET=$(cat ~/sadhana-push-secret.txt) tools/send-push.sh "🙏 Jai Shri Ram" "Time for today's jaap"`
3. The reply now shows `iphones` and `androids`; `sent` should equal `phones`.
   - `FCM_SERVICE_ACCOUNT not set` → step B's first command.
   - `SENDER_ID_MISMATCH` → google-services.json is from a different Firebase project than the service-account key.
   - `UNREGISTERED` → that phone uninstalled the app; its token is removed automatically.
