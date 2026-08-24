# circleci-workflow-queue

[![CircleCI Build Status](https://circleci.com/gh/promiseofcake/circleci-workflow-queue.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/promiseofcake/circleci-workflow-queue) [![CircleCI Orb Version](https://badges.circleci.com/orbs/promiseofcake/workflow-queue.svg)](https://circleci.com/orbs/registry/orb/promiseofcake/workflow-queue) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/promiseofcake/circleci-workflow-queue/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

## Introduction

Originally forked from <https://github.com/eddiewebb/circleci-queue> and updated to reduce the use-cases, and migrate to the CircleCI V2 API

The purpose of this Orb is to add a concept of a queue to specific branch's workflow tasks in CircleCi. The main use-case is to isolate a set of changes to ensure that one set of a thing is running at one time. Think of smoke-tests against a nonproduction environment as a promotion gate.

Additional use-cases are for queueing workflows within a given pipeline (a feature missing today from CircleCi).

## ⚠️ Consider CircleCI Serial Groups first

As of March 2025, CircleCI ships a native **[Serial Groups](https://circleci.com/docs/guides/orchestrate/controlling-serial-execution-across-your-organization/)** feature that serializes execution without an orb, an API token, or a polling loop. For the common "only one deploy runs at a time" use-case it is the recommended approach, and the upstream orb this project was forked from ([`eddiewebb/circleci-queue`](https://github.com/eddiewebb/circleci-queue)) has been deprecated in its favor.

Tag the jobs that must not run concurrently with a shared `serial-group` key:

```yaml
version: 2.1

workflows:
  deploy:
    jobs:
      - test
      - build
      - deploy:
          serial-group: << pipeline.project.slug >>/deploy-group
          requires:
            - test
            - build
```

Jobs sharing a `serial-group` value run one at a time; the value chooses the scope (e.g. `<< pipeline.project.slug >>/...` for per-project). See the [official docs](https://circleci.com/docs/guides/orchestrate/controlling-serial-execution-across-your-organization/) for the current syntax and limits.

**This orb is still worth using when Serial Groups' constraints block you:**

- **You need workflow- or pipeline-level serialization, not per-job.** Serial Groups is applied per job; this orb blocks at the workflow level, gating an entire workflow behind one queue step.
- **You need to wait longer than 5 hours.** Serial Groups auto-cancels a job that waits in the queue beyond 5 hours; this orb's `time` is configurable, and `pipeline_queue` defaults to waiting indefinitely (`0`).
- **You want the extra knobs.** `only_on_branch`, `ignored_workflows`, `include_on_hold`, and `dont_quit` (proceed anyway on timeout) have no direct Serial Groups equivalent.

If none of the "still worth using" cases apply, prefer the native feature.

## Configuration Requirements

In order to use this orb you will need to export a `CIRCLECI_API_TOKEN` secret added to a context of your choosing. It will authenticate against the CircleCI API to check on workflow status. (see: <https://circleci.com/docs/api/v2/index.html#section/Authentication>)

## Custom Executors

Both `global_queue` and `pipeline_queue` jobs now support custom executors. By default, they use a small Docker executor with `cimg/base:stable`, but you can provide your own executor for more control over the execution environment.

### Example: Using a Custom Docker Executor

```yaml
version: 2.1
orbs:
  workflow-queue: promiseofcake/workflow-queue@3

executors:
  nodejs-executor:
    docker:
      - image: cimg/node:18.0
    resource_class: medium

workflows:
  deploy:
    jobs:
      - workflow-queue/global_queue:
          context: deployment-context
          executor: nodejs-executor
```

---

## Jobs & Parameters

### `global_queue`

Blocks the workflow until it is the oldest running workflow on the branch (across all pipelines), then continues. Use this to serialize deploys so only one runs at a time.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `executor` | executor | `default` (`cimg/base:stable`, small) | Executor to run the queue job on. |
| `time` | string | `"10"` | Minutes to wait for the lock before giving up. |
| `dont_quit` | boolean | `false` | If `true`, let the job proceed once `time` expires instead of cancelling/failing. |
| `only_on_branch` | string | `"*"` | Only queue on this branch; `*` queues on every branch. |
| `confidence` | string | `"1"` | Number of consecutive "no previous workflows" confirmations required before proceeding, to guard against workflows that are pending but not yet visible in the API. Increase if you see races. |
| `ignored_workflows` | string | `""` | Comma-separated workflow names to ignore when deciding whether to block (e.g. the queue workflow itself). |
| `include_on_hold` | boolean | `false` | Treat `on_hold` (awaiting-approval) workflows as running and block on them. |
| `debug` | boolean | `false` | Emit additional debug logging. |

### `pipeline_queue`

Blocks a workflow until all _other_ workflows in the **same pipeline** have completed. Use this for one "final" workflow that must run after everything else in the pipeline.

> **Note:** apply `pipeline_queue` to exactly **one** workflow per pipeline. If two workflows in the same pipeline both queue, each waits for the other and they deadlock until `time` expires (or forever, since the default `time` is `0` = wait indefinitely). Ordering/tiebreaking only exists in `global_queue`, not here.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `executor` | executor | `default` (`cimg/base:stable`, small) | Executor to run the queue job on. |
| `time` | string | `"0"` | Minutes to wait before timing out. `0` waits indefinitely. |
| `dont_quit` | boolean | `false` | If `true`, let the job proceed once `time` expires instead of failing. Only applies when `time > 0`. |
| `confidence` | string | `"1"` | Consecutive "no running workflows" confirmations required before proceeding. Increase if you see races. |
| `debug` | boolean | `false` | Emit additional debug logging. |

---

## Resources

[CircleCI Orb Registry Page](https://circleci.com/orbs/registry/orb/promiseofcake/workflow-queue) - The official registry page of this orb for all versions, executors, commands, and jobs described.

[CircleCI Orb Docs](https://circleci.com/docs/2.0/orb-intro/#section=configuration) - Docs for using, creating, and publishing CircleCI Orbs.

### How to Contribute

We welcome [issues](https://github.com/promiseofcake/circleci-workflow-queue/issues) to and [pull requests](https://github.com/promiseofcake/circleci-workflow-queue/pulls) against this repository!

### How to Publish An Update

1. Merge pull requests with desired changes to the main branch.
    - For the best experience, squash-and-merge and use [Conventional Commit Messages](https://conventionalcommits.org/).
2. Find the current version of the orb.
    - You can run `circleci orb info promiseofcake/workflow-queue | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/promiseofcake/circleci-workflow-queue/releases/new) on GitHub.
    - Click "Choose a tag" and _create_ a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
      - We will have an opportunity to change this before we publish if needed after the next step.
4. Click _"+ Auto-generate release notes"_.
    - This will create a summary of all of the merged pull requests since the previous release.
    - If you have used _[Conventional Commit Messages](https://conventionalcommits.org/)_ it will be easy to determine what types of changes were made, allowing you to ensure the correct version tag is being published.
5. Now ensure the version tag selected is semantically accurate based on the changes included.
6. Click _"Publish Release"_.
    - This will push a new tag and trigger your publishing pipeline on CircleCI.
