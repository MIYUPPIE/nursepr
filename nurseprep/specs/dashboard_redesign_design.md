# Design doc: app-wide page/dashboard redesign

## Scope

All 17 authenticated LiveViews (9 student-facing, 8 admin) plus both app
shells (`Layouts.student`, `Layouts.admin`), brought to the same visual
quality bar as the just-shipped homepage/login redesign: real hierarchy,
brand-colored accents from the logo palette, considered empty/loading
states — not just re-tinted defaults.

Out of scope: `mount`/`handle_event`/`handle_params` logic, assign names,
route structure, DB queries. This is a presentation-layer pass. Every
LiveView's behavior stays byte-identical; only `render/1` markup and a
few new shared components change.

## Frontend

**New shared primitives in `core_components.ex`** (reuse over one-off
markup per page, and a single place to keep the visual language
consistent):

- `header/1` (existing) gains an optional `:icon` attr — an icon chip
  next to the title, used on pages where it earns its place (Tutor,
  Analytics, admin Dashboard).
- `stat_card/1` (existing, used by dashboard + analytics): icon moves
  into a colored rounded chip instead of a bare glyph; kept
  attr-compatible so no call site needs to change.
- `status_badge/1` (new): every admin list hand-rolls its own
  `status_badge(status)` function mapping published/success→success,
  rejected/flagged/failed→error, pending→warning, else→ghost. Six
  near-identical private functions collapse into one component.
- `empty_state/1` (new): consistent icon + message treatment for "no
  ranked activity", "nothing pending in review", "no weak areas yet"
  etc., replacing ad-hoc `text-base-content/60` divs.
- `section/1` (new): the repeated `<h3 class="font-semibold mb-2">`
  pattern (Weak areas, Recent sessions, Review, Payment history,
  Accuracy by topic, Admin review history) becomes one slot-based
  component with consistent spacing and an optional trailing action.

**Shells:**

- `Layouts.student`: sharpen the active nav-item state (brand-colored
  pill instead of default `btn-active` grey), tidy the mobile dropdown.
- `Layouts.admin`: brand-colored active state in the sidebar to match,
  slightly richer sidebar header (logo + "Admin" chip instead of two
  plain lines).

**Per-page:** stronger opening (icon/eyebrow where it earns its place),
consistent card/section rhythm, the new `empty_state`/`status_badge`
components wherever a page currently hand-rolls one. No copy changes
except where a string was only ever a code comment for a CSS class
(none expected) — all user-visible strings that tests assert on
(`assert html =~ "..."`) are preserved verbatim.

## Backend

No backend changes. All data flow, authorization checks
(`require_admin`, `require_strict_admin`, ownership checks like
`session.user_id != current user`), and business logic are untouched.

## Security

- Presentation-only diff: no new routes, no new params accepted, no
  changes to what data a `mount/3` loads or exposes.
- `status_badge`/`empty_state`/`section` are pure display components —
  no new user input rendered unescaped (HEEx auto-escapes `{}`
  interpolation by default; nothing here switches to `raw/1` except the
  AI tutor's existing, already-reviewed Markdown rendering path, which
  is untouched).
- Admin-only markup (role chips, manual grant form, revoke links) stays
  behind the same `:require_admin` / `:require_strict_admin` route
  gates — the redesign doesn't touch `router.ex`.

## Verification

- `mix test test/nurseprep_web/live/` must stay green (baseline: 79
  tests, 0 failures) — these assert on visible text/flash content, not
  markup structure, so restyling is safe as long as copy is preserved.
- `mix format --check-formatted` on every touched file.
- Screenshot spot-check of dashboard, practice, admin dashboard, and
  review queue in both themes via the running dev server.
