---
name: functional-check
description: Run the EduIDE functional test plan (docs/testing/) against one environment and write a report. Use when asked to test, check, verify or smoke-test an environment, a release candidate, an upgrade, or a single area such as the warm pool, agent and launch data, workspace retention, service API, landing page or IDE templates. The plan is for the Go control plane (EduIDE 3.x).
---

# Running the functional check

The plan is `docs/testing/README.md` plus one file per module in `docs/testing/modules/`. Read the README first, every time: it holds the safety rules, the setup and the fixtures. This skill is only the order of work.

## 1. Agree on the run

Ask for (or accept from the request) and repeat back before touching anything:

- **Environment**: a directory under `environments/`. If the user names a short form (`test2`, `prod`), map it to the directory and say which one. Check `spec.platform.stack` in its `env.yaml`: the plan covers `go` only. `mannheim.` is `java`: tell the user, run only what README "Java stack: Mannheim only" allows (read-only, old plan at commit `13a6ef3`).
- **Modules**: `all` or a list (`01` is always added).
- **Mode**: `prod-safe` or `full`. Production environments (`eduide.artemis.cit.tum.de`, `bonn.`) are always `prod-safe`. `e2e.` gets no `full` run.
- **Kube context** that reaches the cluster. Never assume the current context.
- For tests labelled `test-only, disruptive`: whether others use the environment right now. For `test-only, destructive`: explicit approval in chat for this run, or skip them.

Browser modules need the user logged in on the landing page. Never type a password; ask the user to log in in the browser pane. Never obtain a user token on production.

## 2. Verify what is deployed

Load the README setup, check the cluster identity, run module 01. Put the versions into the report's run table. If they are not what the user wants tested (wrong chart, preloading not finished, components not ready), stop and say so instead of testing the wrong thing.

## 3. Run the modules

- Server modules (01, 03 curl part, 04, 05, 06, 07, 09, 10) are independent. When several are selected, run them in parallel with one subagent each. Give each subagent: the environment variables from the setup, its module file, the README safety rules and fixture helpers, its own name prefix (`ft-<module>-`), the mode, and the instruction to return a results table (ID, result, evidence, notes) plus findings and exploration notes, never secret values. Tests that restart or stop the operator or the service (OPR-10, OPR-13, OPR-14, POOL-09, POOL-17, API-18, SEC-14, LAND-09) must not overlap with each other or with other modules' running tests: run them last, one at a time, from the main agent.
- Browser modules (02, 08, 12, and the token-based tests of 03) share one browser and one login: run them sequentially in the main agent.
- Browser modules need the user logged in; the fixtures need a kube context that reaches the cluster (see README setup: `CTX`, `P`). Pool scaler tests (POOL-14 to POOL-17) need `test3`. Module 11 runs alone, after everything else, because it redeploys the environment.
- Record `pass`, `fail`, `blocked` or `skipped` for every selected test. When an expectation fails, first check whether the plan or the code is wrong (read the source named in the module) and say which in the notes.

## 4. Explore

Spend real time beyond the scripted tests (README "Beyond the plan", each module's Explore section). Stay within the mode. Record everything tried, including what found nothing.

## 5. Clean up

Run `ft_cleanup`, restore anything a disruptive test changed (replicas of operator, service, authz or the pool scaler, patched templates and pools), remove `ft.tok` from the browser's sessionStorage, and check `k get idesessions,ideworkspaces,idepools,idetemplates,pods,secrets | grep ft-` is empty. List leftovers in the report if any remain.

## 6. Report and plan updates

Write `docs/testing/reports/<YYYY-MM-DD>-<environment>-<n>.md` from `docs/testing/report-template.md`. Before saving, scan it for anything that looks like a token, an email address of a real user, or a Secret value, and redact it.

Propose plan changes in the report's "Plan updates" section. Ask the user whether to open a PR with the report and, separately, one that applies the plan updates (edit the module, keep IDs stable, add a changelog line to `docs/testing/README.md`).

Tell the user: results per module (pass/fail/blocked/skipped counts), the findings by severity, what was skipped and why, and the report path.
