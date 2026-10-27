# Universe CRM

A browser demo of the Universe CRM process, in Bahasa Indonesia, built from the CRM PRD (Odoo implementation). It runs as a single static page, so it works on GitHub Pages with no build step.

## What's inside

- **Dasbor**: a 3D Universe cube hero (Three.js), sales team, expected revenue per team, revenue per stage, the PRD's KPIs (Leads, % Opportunities, Expected and Prorated Revenue, Days to Assign / Opportunity / Close), weekly and monthly statistics, a "Perlu tindakan" list, a 3D P0–P7 pipeline, a week agenda, top opportunities with 3D thumbnails, and an activity feed.
- **Leads**: create leads and convert them into opportunities at P0.
- **Peluang (P0–P7)**: a kanban board with drag and drop, linked to the 3D pipeline.
- **Quotation & Sales Order**: the full status flow. Quotation → Quotation Sent → Giro Receipt → Giro OK / Giro Reject → Pro Forma INV Sent → Sales Order → BAST. It also covers:
  - the TOP Giro rule and the "Transfer only for CBD/COD" rule
  - Manager + Cluster approval to resend a quotation
  - `SO/YYYY/MM/XXXX` numbering that resets each month
  - locked Sales Orders
  - a BAST tab that opens only after delivery
  - print previews
- **Pelanggan / Produk**: master data, with customer pricing rules applied to order lines.
- **Laporan CRM**: opportunity analysis grouped by stage, salesperson, team, medium, source or priority.

## Demo accounts

Password for all accounts: `universe2026`

| Username | Role |
|---|---|
| `rina` | Sales |
| `hendra` | Manager |
| `maya` | Cluster |
| `budi` | Inactive (login is refused) |

You can also switch users from the selector at the top right to try the approval flow.

## Notes

- All data is sample data. It lives in memory and resets when the page reloads. The page is not connected to Odoo, and the "Web Apps" sync indicator only simulates the PRD's sync.
- The Quotation, Pro Forma Invoice and BAST printouts use placeholder layouts until Universe's own designs are available.
- Three.js r128 loads from cdnjs, and fonts load from Google Fonts.

## Run locally

Open `index.html` in a browser, or serve the folder:

```bash
python3 -m http.server 8000
```
