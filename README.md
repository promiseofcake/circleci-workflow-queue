# circleci-workflow-queue

[![CircleCI Build Status](https://circleci.com/gh/promiseofcake/circleci-workflow-queue.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/promiseofcake/circleci-workflow-queue) [![CircleCI Orb Version](https://badges.circleci.com/orbs/promiseofcake/workflow-queue.svg)](https://circleci.com/orbs/registry/orb/promiseofcake/workflow-queue) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/promiseofcake/circleci-workflow-queue/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

## Introduction

Originally forked from <https://github.com/eddiewebb/circleci-queue> and updated to reduce the use-cases, and migrate to the CircleCI V2 API

The purpose of this Orb is to add a concept of a queue to specific branch's workflow tasks in CircleCi. The main use-case is to isolate a set of changes to ensure that one set of a thing is running at one time. Think of smoke-tests against a nonproduction environment as a promotion gate.

Additional use-cases are for queueing workflows within a given pipeline (a feature missing today from CircleCi).

## Configuration Requirements

In order to use this orb you will need to export a `CIRCLECI_API_TOKEN` secret added to a context of your choosing. It will authentcation against the CircleCI API to check on workflow status. (see: <https://circleci.com/docs/api/v2/index.html#section/Authentication>)

## Custom Executors

Both `global-queue` and `pipeline-queue` jobs now support custom executors. By default, they use a small Docker executor with `cimg/base:stable`, but you can provide your own executor for more control over the execution environment.

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
      - workflow-queue/global-queue:
          context: deployment-context
          executor: nodejs-executor
```

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
