<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/yard-link/README-Dark.svg">
  <img src="assets/yard-link/README-Light.svg" alt="Yard Link | Container and yard management" width="100%">
</picture>

# Yard Link

Container and yard management for drayage fleets. Drivers work trips from a phone; dispatchers run the desk from a web console. Every employer hosts their own server.

Yard Link is the rebuild of Sensible Logistics "Yard Manager". The working application was carried forward and extended, so its workflows are the same code that ran before. What changed and what is still open is tracked in [`docs/PARITY.md`](docs/PARITY.md).

| Part | Where | What it is |
| :--- | :--- | :--- |
| Server + web app | repo root | Nuxt 4 / Nitro, PostgreSQL, Drizzle. Driver screens and the dispatcher console. |
| iPhone app | [`ios/`](ios) | Native SwiftUI client. It holds no business rules; it calls the server. |

## Run it

```bash
docker compose up -d
```

Open `http://<this-computer>:3847`. The first visit shows the setup wizard: company, first dispatcher account, and the address phones will use. There is no `.env` file and nothing to edit. The database password and session secret are generated on first start; everything else is entered in the web app and can be changed later under **Settings**.

Back up the three Docker volumes: `yardlink-db`, `yardlink-data`, `yardlink-secrets`.

### Connecting phones

Settings shows a QR code. A driver opens the iPhone app, sees **Connect to Your Employer**, scans the code, and signs in. The code holds the server address and company name only. New people create an account with the **join code** shown beside it, and a dispatcher approves them under **Drivers**.

iPhones need an `https` address to reach the server away from the office network. Put the server behind any reverse proxy with a certificate and enter that address in Settings.

## Develop

```bash
npm install
docker compose up -d db secrets        # database only
export DATABASE_URL=postgresql://yardlink:$(docker compose exec db cat /run/yardlink/db-password)@localhost:5432/yardlink
export NUXT_SESSION_PASSWORD=$(openssl rand -hex 32)
npm run db:migrate
npm run dev
```

```bash
npm test          # rule tests (Vitest)
npm run typecheck
npm run lint
```

iPhone app: open `ios/YardLink.xcodeproj` in Xcode, choose your team under Signing, and run.

## How the pieces fit

- **All rules run on the server.** Pickup, drop-off, swaps, chassis handling, duty cycles, dispatch tasks, time cards, OCR and ShipCSX lookups are server code. The web app and the iPhone app send actions and show results.
- **Container duty cycles.** A container's history is filed under a duty cycle: it opens when the box leaves a marine terminal or rail yard and completes when it is returned to one. A reused container number starts a new cycle; earlier cycles are never touched. Rules: `shared/utils/duty-cycle.ts`. Tests: `test/duty-cycle.spec.ts`.
- **Chassis** keep one continuous history and a list of every container they carried, each linked to that container's duty cycle.
- **Messages** replace email and SMS. Each driver has a dispatch conversation shared by all dispatchers.
- **Camera number reading** is done by the server's own OCR engine. The phone uploads a photo; no outside recognition service is called.
