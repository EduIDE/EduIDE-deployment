# Functional check <environment>, <YYYY-MM-DD> (run <n>)

Copy to `docs/testing/reports/<YYYY-MM-DD>-<environment>-<n>.md`. No tokens, cookies, Secret values, session env values or personal data anywhere in this file; write `<redacted>`.

## Run

| Field | Value |
|---|---|
| Environment | `<directory under environments/>` (namespace `<ns>`, cluster `<cluster>`) |
| Date and time | `<start> to <end>`, timezone |
| Run by | `<person, or agent and model>`, started by `<person>` |
| Mode | `prod-safe` or `full` |
| Modules | `all` or `01,03,...` |
| Plan version | commit of `docs/testing/` used |
| Chart `eduide` / `eduide-cluster` | `<x.y.z>` / `<x.y.z>` (pinned in env.yaml: `<x.y.z>`) |
| Operator / service image | `<tag>` |
| Landing page image | `<tag>` |
| IDE images | `<tag>` (scorpio `<v>`, data bridge `<v>`, monitor `<v>`) |
| Garbage collector image | `<tag>` |
| Apps used | `APP_POOL=<name>`, `APP_STD=<name>` |
| Fixtures left behind | none / list |

## Summary

<Two to five sentences: is the environment fit for its purpose, what blocks a release, what needs attention.>

| Result | Count |
|---|---|
| pass | |
| fail | |
| blocked | |
| skipped | |

## Results

One row per selected test. Evidence is a command and the relevant output lines, a screenshot path, or a link to a workflow run.

| ID | Result | Evidence | Notes |
|---|---|---|---|
| PLAT-01 | pass | `helm list`: eduide 3.0.0 ... | |
| ... | | | |

## Findings

| # | Severity | Test / area | Finding | Steps to reproduce | Suggested fix | Issue / PR |
|---|---|---|---|---|---|---|
| 1 | high / medium / low / info | | | | | |

Severity: **high** breaks students' work or security, **medium** degrades a main flow or has a workaround, **low** cosmetic or rare, **info** observation without a defect.

## Exploration

What was tried beyond the scripted tests, including what found nothing.

| Idea (module or heuristic) | What was done | Outcome |
|---|---|---|
| | | |

## Plan updates

Proposed changes to `docs/testing/`, applied in a follow-up PR (see "Changing the plan" in the README). Write new tests with all fields.

- New test: ...
- Changed expectation: <ID>, because <evidence that the code is right and the plan was wrong>
- Retire: <ID>, because ...
- New Explore idea: ...
- Ideas for new tests nobody has written yet: ...
