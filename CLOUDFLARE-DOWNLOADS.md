# Android app downloads on Cloudflare R2 — your steps

The code is written and committed **but not pushed** — do these in order, or the site's deploy fails.

## 1. Create the bucket (dashboard, 1 min)
Cloudflare dashboard → **R2 Object Storage** → **Create bucket** → name **`sadhana-downloads`** (exactly) →
location Automatic → **Create**. Leave it **private** (the website serves it; no public access needed).

## 2. Log Wrangler in (once)
```
cd ~/Developer/naam-jaap-sadhna
npx wrangler login
```
A browser window opens → **Allow**.

## 3. Upload the current Android app
```
tools/upload-apk.sh
```
It takes the latest build from GitHub (v2.3.3) and puts it in the bucket as `sadhana.apk`.
(The "check:" line will say 404 for now — the website doesn't serve it until step 4.)

## 4. Publish the website change
```
git push origin main
```
Cloudflare rebuilds the site (1–2 min). Then:
```
curl -sI https://vanarsathi.online/download/sadhana.apk | head -3
```
should show `HTTP/2 200` and `content-type: application/vnd.android.package-archive`.

## 5. Test on a phone
On an Android phone open vanarsathi.online → the download button (top right) → **Download** — it now comes from
vanarsathi.online itself.

## New Android versions later
After a new `vX.Y.Z` build finishes on GitHub: `tools/upload-apk.sh` — that's all (the link never changes).

## Cleanup (optional, after step 5 works)
The old public mirror repo `ellomehllo/bin-mirror-7q` is no longer used; you can delete it on GitHub
(Settings → Delete this repository), or tell Claude to.
