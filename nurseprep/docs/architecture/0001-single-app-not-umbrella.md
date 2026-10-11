# ADR 0001: Single Phoenix app with bounded contexts, not an umbrella

## Status

Accepted

## Context

The organization's default engineering guidance calls for services-first architecture:
one concern per top-level directory, sharp contracts at boundaries, independent test
suites, and a layout where two people (or two agent sessions) can work in different
parts of the system without colliding. Taken literally, that points at a Phoenix
umbrella project-`apps/nurseprep_accounts`, `apps/nurseprep_questions`,
`apps/nurseprep_quizzes`, `apps/nurseprep_subscriptions`, `apps/nurseprep_analytics`,
`apps/nurseprep_ai_tutor`, `apps/nurseprep_whatsapp`, `apps/nurseprep_web`.

The same guidance also says: no framework-of-the-month, no clever abstractions for
hypothetical reuse, don't design for future requirements that aren't concrete yet.

These two instructions are in tension for this project at this moment.

## Decision

Build NursePrep as a **single Phoenix application** with bounded contexts under
`lib/nurseprep/{accounts,questions,quizzes,subscriptions,analytics,ai_tutor,whatsapp}/`.
Each context exposes a small public API module (e.g. `NursePrep.Questions`) that is the
only thing other contexts or the web layer may call-no reaching into another
context's `Ecto.Schema` modules directly. Each context gets its own test file/directory
(`test/nurseprep/questions_test.exs`, etc.) that can be run in isolation
(`mix test test/nurseprep/questions_test.exs`).

## Why not the umbrella

An umbrella's actual payoff is independent deploy units, independent releases, and
genuinely separate teams working in parallel without stepping on each other. None of
that has a concrete referent here: this is one deploy unit (one Phoenix release, one
Postgres database), built primarily in one continuous effort, by one team.

What an umbrella *would* cost, today, for zero present benefit:

- Cross-context foreign keys (e.g. `questions.subject_id` is fine within one app, but
  `quiz_answers.user_id` referencing an `Accounts`-owned schema from a `Quizzes` app
  in an umbrella forces either a shared `apps/nurseprep_data` app-which defeats the
  "one concern per app" premise it was meant to enforce-or duplicated schema
  knowledge across app boundaries).
- Ecto's migration story across umbrella apps is itself an added layer of ceremony;
  a single `priv/repo/migrations` directory shared by one `Repo` is simpler and no
  less correct.
- Per-app `mix.exs`, `config/config.exs` wiring, and `Application` boot-order concerns
  across 8 apps, purely to satisfy a boundary that isn't being crossed by independent
  teams or independent deploys today.

A context with a minimal public API and its own test suite already gives the practical
properties the services-first rule is protecting: you can reason about `Questions` in
isolation, test it in isolation, and a future session working on `WhatsApp` will not
need to touch `lib/nurseprep/quizzes/` to get its job done. This is the idiomatic BEAM
shape for a bounded context, and it is what Phoenix's own context generators produce
by default.

## Escape hatch

If a *concrete* need materializes later-e.g. the WhatsApp integration needs to run
as its own scaled-independently release, or a second team genuinely starts working in
parallel on a context-extracting that context into its own OTP app (umbrella or
fully separate release) is a mechanical refactor precisely because the public-API
boundary was already enforced from day one. That is cheap to do later and expensive to
speculatively build now.

## Consequences

- Code review must enforce the "no reaching into another context's schema" rule since
  there's no compiler boundary forcing it (an umbrella would get this for free via
  separate `:applications` lists-this is the one real thing we give up).
- All contexts share one `NursePrep.Repo` and one running BEAM node for now.
