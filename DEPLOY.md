# Deploy Mattermost forka na Railway

Korak-po-korak uputstvo za hostovanje ovog forka na Railway-u sa privatnog
GitHub repoa. Railway gradi direktno iz Dockerfile-a u rootu repoa.

## Šta je u repo-u dodato za deploy

| Fajl | Šta radi |
|---|---|
| `Dockerfile` | Multi-stage build: webapp (Node 24) → server (Go 1.25) → runtime (Ubuntu) |
| `.dockerignore` | Smanjuje build kontekst (bez `.git`, `node_modules`, e2e testova...) |
| `railway.toml` | Railway config (Dockerfile builder, healthcheck, restart policy) |

## Preduslovi

- GitHub repo (privatan je OK) sa ovim fajlovima u `main` grani
- Railway nalog (Hobby plan minimum, Pro preporučeno za realnu upotrebu)

## 1. Kreiraj Railway projekat

1. Otvori [railway.app](https://railway.app/new) → **New Project**.
2. Dodaj PostgreSQL prije servera:
   - **+ New** → **Database** → **PostgreSQL**
   - Sačekaj zelenu tačku (~30 sekundi).

## 2. Dodaj Mattermost servis iz GitHub repoa

1. U istom projektu: **+ New** → **GitHub Repo**.
2. Ako Railway nema pristup tvom forku:
   - **Configure GitHub App** → odobri **samo** ovaj repo (Only select repositories).
3. Vrati se u Railway → odaberi fork.
4. Railway detektuje `Dockerfile` i `railway.toml` i pokreće prvi build automatski.

> Pusti prvi build da pukne ako pukne — dijagnozu radimo iz Railway "Deployments" loga.

## 3. Postavi environment varijable

U Mattermost servisu → **Variables** tab → **Raw Editor** → zalijepi:

```
# === Database ===
MM_SQLSETTINGS_DRIVERNAME=postgres
MM_SQLSETTINGS_DATASOURCE=${{Postgres.DATABASE_URL}}?sslmode=require

# === Server ===
MM_SERVICESETTINGS_SITEURL=https://${{RAILWAY_PUBLIC_DOMAIN}}
MM_SERVICESETTINGS_LISTENADDRESS=:8065

# === Storage (lokalni Volume; za S3 vidi sekciju 7) ===
MM_FILESETTINGS_DIRECTORY=/mattermost/data/
MM_PLUGINSETTINGS_DIRECTORY=/mattermost/plugins/
MM_PLUGINSETTINGS_CLIENTDIRECTORY=/mattermost/client/plugins/
MM_LOGSETTINGS_FILELOCATION=/mattermost/logs/

# === Email (Resend SMTP relay — isti API key kao B2B projekat) ===
MM_EMAILSETTINGS_SMTPSERVER=smtp.resend.com
MM_EMAILSETTINGS_SMTPPORT=465
MM_EMAILSETTINGS_SMTPSERVERTIMEOUT=10
MM_EMAILSETTINGS_SMTPUSERNAME=resend
MM_EMAILSETTINGS_SMTPPASSWORD=<RESEND_API_KEY>
MM_EMAILSETTINGS_CONNECTIONSECURITY=TLS
MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=true
MM_EMAILSETTINGS_REQUIREEMAILVERIFICATION=true
MM_EMAILSETTINGS_FEEDBACKEMAIL=noreply@braytron.rs
MM_EMAILSETTINGS_FEEDBACKNAME=Braytron Chat
MM_EMAILSETTINGS_REPLYTOADDRESS=noreply@braytron.rs
MM_EMAILSETTINGS_NOTIFICATIONCONTENTS=full

# === Push notifikacije za mobilnu aplikaciju ===
MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS=true
MM_EMAILSETTINGS_PUSHNOTIFICATIONSERVER=https://push-test.mattermost.com
MM_EMAILSETTINGS_PUSHNOTIFICATIONCONTENTS=full

# === Razno ===
TZ=UTC
```

`${{Postgres.DATABASE_URL}}` i `${{RAILWAY_PUBLIC_DOMAIN}}` su Railway reference
(oblik `${{ServisIme.VARIJABLA}}`) — ne pišu se kao tekst, Railway ih razrešava.

> **`<RESEND_API_KEY>`** zamijeni stvarnim ključem iz Resend dashboarda
> (https://resend.com/api-keys). Preporučujem novi ključ samo za Mattermost
> (naziv: "mattermost", permission: "Sending access") da možeš revoke-ovati
> nezavisno od B2B-a.
>
> Domen `braytron.rs` je već verifikovan na Resend nalogu, tako da from
> address radi out-of-the-box. Ako želiš drugi from (npr. `chat@braytron.rs`),
> samo promijeni `FEEDBACKEMAIL` i `REPLYTOADDRESS` — ne treba dodatan DNS.

## 4. Generiši javni domen

**Settings** → **Networking** → **Generate Domain** → target port: **`8065`**.

## 5. Dodaj Volume (KRITIČNO)

Bez volume-a sve uploadovane slike, fajlovi i pluginovi se brišu na svaki redeploy.

**Settings** → **Volumes** → **+ New Volume**:
- Mount path: `/mattermost/data`
- Size: 5–10 GB za početak

> Opcionalno možeš dodati zasebne volume-e za `/mattermost/plugins` i
> `/mattermost/logs`, ali jedan na `/mattermost/data` pokriva 90% slučajeva.

## 6. Trigger deploy i prati build

Railway već gradi nakon koraka 2. Ako trebaš ručno triger-ovati:
- **Deployments** tab → **... (tri tačke)** → **Redeploy**.

Prvi build traje **20–35 minuta** (Node deps + Go build + Docker assembly).
Cache nakon toga svodi build na ~5–10 min ako mijenjaš samo Go ili samo webapp.

## 7. Prvi login

Otvori `https://<tvoj-railway-domen>` → kreiraj prvog korisnika (postaje admin
automatski) → **System Console** → konfiguriši ostatak (SMTP, file storage itd).

---

## Resursi i očekivani trošak

| Resurs | Minimum | Preporučeno |
|---|---|---|
| Mattermost servis RAM | 1 GB | 2 GB |
| Mattermost servis CPU | 0.5 vCPU | 1 vCPU |
| PostgreSQL | default | default |
| Volume | 5 GB | 10–20 GB |

Realan trošak na Railway-u za solo/mali tim: **~$15–25/mjesec** ukupno.

---

## Tipični problemi i fixevi

### Build pukne na webapp `npm run build` (out of memory)
Već imamo `NODE_OPTIONS="--max-old-space-size=6144"` u Dockerfile-u. Ako i dalje
puca, Railway builder nema dovoljno RAM-a — pređi na Pro plan ili build-uj
preko GitHub Actions pa push-uj image na GHCR (vidi sekciju ispod).

### Build pukne na `make build-linux-amd64` sa Go greškom
99% slučajeva: tvoja izmjena u `server/` ima sintaksnu grešku ili broken import.
Build prvo lokalno: `cd server && make build-linux-amd64`.

### Server starta ali domen vraća 502
- Provjeri `MM_SERVICESETTINGS_LISTENADDRESS=:8065`
- Provjeri da je **target port = 8065** u Networking
- Pogledaj logove: ako vidiš `unable to connect to database` → DATABASE_URL referenca nije razriješena (provjeri da Postgres servis radi i da je ime servisa baš `Postgres`)

### Healthcheck timeout
Prvi boot inicijalizuje DB šemu — može potrajati 1–3 minute. `healthcheckTimeout = 300`
u `railway.toml` to pokriva. Ako i dalje fail-uje, povećaj na 600.

---

## Plugin koji si dodao (`threadbot_sticky`)

Mattermost pluginovi nisu dio glavnog server build-a. Pravilno integrisanje:

1. **Build pluginu zasebno** (svaki plugin ima svoj `Makefile` i `plugin.json`):
   ```
   cd plugins/threadbot_sticky
   make dist
   ```
   Output: `dist/threadbot-sticky-X.Y.Z.tar.gz`

2. **Pre-package u image** — dodaj na kraj Stage 3 u `Dockerfile`-u:
   ```dockerfile
   COPY --chown=2000:2000 plugins/threadbot_sticky/dist/threadbot-sticky-*.tar.gz \
        /mattermost/prepackaged_plugins/
   ```

3. **Ili upload kroz UI** nakon deploy-a:
   System Console → Plugins → Plugin Management → Upload Plugin.

Pošalji mi strukturu `threadbot_sticky` foldera (`ls plugins/threadbot_sticky/`) pa
ću ti dati tačan build setup.

---

## Update-i nakon prvog deploy-a

Tipičan workflow:

```bash
# napraviš izmjenu lokalno
git add .
git commit -m "..."
git push origin main
```

Railway automatski:
1. Detektuje push
2. Pokrene build (sa cache-om: 5–10 min)
3. Deploy-uje novu verziju (zero-downtime ako healthcheck prođe)

## Migracija na GH Actions → GHCR (kasnije, opcionalno)

Ako Railway build-ovi počnu da te bole (sporost ili koštanje), prebaci se na:

1. GitHub Actions build-uje image na svakom push-u na main
2. Push image na `ghcr.io/<user>/mattermost:latest`
3. Railway → Source → Docker Image (umjesto GitHub Repo) → daj GHCR PAT credentials
4. Railway → Settings → "Watch for image updates" = on

Tada Railway samo pull-uje gotov image (~30 sek deploy umjesto 10+ min build).
