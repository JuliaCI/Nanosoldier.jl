# Nanosoldier.jl

[![Build Status](https://travis-ci.org/JuliaCI/Nanosoldier.jl.svg?branch=master)](https://travis-ci.org/JuliaCI/Nanosoldier.jl)

This package contains the infrastructure powering the @nanosoldier CI bot used by the Julia language.


## Quick start

If you're a collaborator in the JuliaLang/julia repository, you can submit CI jobs by
commenting on commits or pull requests. The @nanosoldier bot looks for a special "trigger
phrase" in your comment, and if the trigger phrase is found, it is parsed by the bot to
configure and submit a CI job.

The trigger phrase syntax is:

```
@nanosoldier `command(args..., kwargs...)`
```

Backticks are mandatory. If the job is accepted, a status update will be pushed to the
commit you commented on (look for a yellow dot, green check or red cross). Once the job
finishes, @nanosoldier will reply with a comment, and upload results to the
[NanosoldierReports](https://github.com/JuliaCI/NanosoldierReports) repository.

There are two kinds of jobs you can invoke: **benchmark jobs**, which run the
[BaseBenchmarks.jl](https://github.com/JuliaCI/BaseBenchmarks.jl) suite, and **package test
jobs** which rely on [PkgEval.jl](https://github.com/JuliaCI/PkgEval.jl) to run the test
suite of all registered packages.

**Note that only one job can be triggered per comment.**

One of the most common invocations runs all benchmarks on your PR, comparing against the
current Julia master branch:

```
@nanosoldier `runbenchmarks()`
```

Similarly, you can run all package tests, e.g. if you suspect your PR might be breaking:

```
@nanosoldier `runtests()`
```

Both operations take a long time, so it might be wise to restrict which benchmarks you want
to run, or which packages you want to test:

```
@nanosoldier `runbenchmarks("linalg")`

@nanosoldier `runtests(["JSON", "Crayons"])`
```

When a job is completed, @nanosoldier will reply to your comment to tell you how the job
went and link you to any relevant results.


## Available job types

CI jobs are implemented in this package as subtypes of `Nanosoldier.AbstractJob`. See
[here](https://github.com/JuliaCI/Nanosoldier.jl/blob/master/src/jobs/jobs.jl) for a
description of the interface new job types need to implement.

### `BenchmarkJob`

#### Execution Cycle

A `BenchmarkJob` has the following execution cycle:

1. Pull in the JuliaLang/julia repository and build the commit specified by the context of
   the trigger phrase.
2. Using the new Julia build, fetch the `nanosoldier` branch of the
   [BaseBenchmarks](https://github.com/JuliaCI/BaseBenchmarks.jl) repository and run the
   benchmarks specified by the trigger phrase.
3. If the trigger phrase specifies a commit to compare against, build that version of Julia
   and perform step 2 using the comparison build.
4. Upload a markdown report to the
   [NanosoldierReports](https://github.com/JuliaCI/NanosoldierReports) repository.

#### Trigger Syntax

A `BenchmarkJob` is triggered with the following syntax:

```
@nanosoldier `runbenchmarks(tag_predicate, vs = "ref")`
```

The `vs` keyword argument is optional; if invoked from a pull request, it will be derived
automatically from the merge base. In other cases, the comparison step (step 3 above) will
be skipped.

The tag predicate is used to decide which benchmarks to run, and supports the syntax defined
by the [tagging
system](https://github.com/JuliaCI/BenchmarkTools.jl/blob/master/doc/manual.md#indexing-into-a-benchmarkgroup-using-tagged)
implemented in the [BenchmarkTools](https://github.com/JuliaCI/BenchmarkTools.jl) package.
Additionally, you can run all benchmarks by using the keyword `ALL`, e.g.
`runbenchmarks(ALL)`, which is the same as specifying no predicate at all.

The `vs` keyword argument takes a reference string which can points to a Julia commit to
compare against. The following syntax is supported for reference string:

- `":branch"`: the head commit of the branch named `branch` in the current repository (`JuliaLang/julia`)
- `"@sha"`: the commit specified by `sha` in the current repository (`JuliaLang/julia`)
- `"#tag"`: the commit pointed to by the tag named `tag` in the current repository (`JuliaLang/julia`)
- `"%self"`: to use the same commit for both parts of the comparison
- `"owner/repo:branch"`: the head commit of the branch named `branch` in the repository `owner/repo`
- `"owner/repo@sha"`: the commit specified by `sha` in the repository `owner/repo`
- `"owner/repo#tag"`: the commit pointed to by the tag named `tag` in the repository `owner/repo`

#### Benchmark Results

Once a `BenchmarkJob` is complete, the results are uploaded to the
[NanosoldierReports](https://github.com/JuliaCI/NanosoldierReports) repository. Each job
has its own directory for results. This directory contains the following items:

- `report.md` is a markdown report that summarizes the job results
- `data.tar.gz` contains raw timing data in JSON format. To untar this file, run
`tar -xzvf data.tar.gz`. You can analyze this data using the
[BenchmarkTools](https://github.com/JuliaCI/NanosoldierReports) package.
- `logs` is a directory containing the build logs and benchmark execution logs for the job.

#### Comment Examples

Here are some examples of comments that trigger a `BenchmarkJob` in various contexts:

```
I want to run benchmarks tagged "array" on the current commit.

@nanosoldier `runbenchmarks("array")`

If this comment is on a specific commit, benchmarks will run on that commit. If
it's in a PR, they will run on the head/merge commit of the PR. If it's on a diff,
they will run on the commit associated with the diff.
```

```
I want to run benchmarks tagged "array" on the current commit, and compare the results
with the results of running benchmarks on commit 858dee2b09d6a01cb5a2e4fb2444dd6bed469b7f.

@nanosoldier `runbenchmarks("array", vs = "@858dee2b09d6a01cb5a2e4fb2444dd6bed469b7f")`
```

```
I want to run benchmarks tagged "array", but not "simd" or "linalg", on the
current commit. I want to compare the results against those of the release-0.4
branch.

@nanosoldier `runbenchmarks("array" && !("simd" || "linalg"), vs = ":release-0.4")`
```

```
I want to run all benchmarks on the current commit. I want to compare the results
against a commit on my fork.

@nanosoldier `runbenchmarks(vs = "christopher-dG/julia@c70ab26bb677c92f0d8e0ae41c3035217a4b111f")`
```

```
I want to run all benchmarks on the current commit. I want to compare the results
against the head commit of my fork's branch.

@nanosoldier `runbenchmarks(vs = "christopher-dG/julia:mybranch")`
```

### `PkgEvalJob`

#### Execution Cycle

A `PkgEvalJob` has the following execution cycle:

1. Pull in the JuliaLang/julia repository and build the commit specified by the context of
   the trigger phrase.
2. Using the new Julia build, test the packages from the
   [General](https://github.com/JuliaRegistries/General) registry as specified by the
   trigger phrase.
3. If the trigger phrase specifies a commit to compare against, build that version of Julia
   and perform step 2 using the comparison build.
4. Upload a markdown report to the
   [NanosoldierReports](https://github.com/JuliaCI/NanosoldierReports) repository.

#### Trigger Syntax

A `PkgEvalJob` is triggered with the following syntax:

```
@nanosoldier `runtests(package_selection, vs = "ref")`
```

The **package selection argument** is used to decide which packages to test. It should be a
list of package names, e.g. `["Example"]`, that will be looked up in the registry.
Additionally, you can test all packages in the registry by using the keyword `ALL`, e.g.
`runtests(ALL)`, which is the same as not providing a package selection argument at all.

The **`vs` keyword argument** is again optional. Its syntax and behavior is identical to the
`BenchmarkJob` `vs` keyword argument.

The evaluation can be further configured by using the `configuration` argument, which
expects a named tuple corresponding to the fields of the `PkgEval.Configuration` type.
By default, this configuration will be used for both sides of the comparison. If you want to
use different configurations for the two sides, you can use the `vs_configuration` argument
in the same way.

One noteworthy invocation is to compare the results between enabling and disabling
assertions:

```
@nanosoldier `runtests(vs = "%self", configuration = (buildflags=["LLVM_ASSERTIONS=1", "FORCE_ASSERTIONS=1"],), vs_configuration = (buildflags=[],))`
```

Another useful example makes PkgEval run under `rr` and use a Julia debug build for a better
debugging experience:

```
@nanosoldier `runtests(configuration = (buildflags=["JULIA_BUILD_MODE=debug"], julia_binary="julia-debug", rr=true))`
```

If no configuration arguments are specified, the defaults as specified by the
`PkgEval.Configuration` constructor are used, with the addition of enabling assertions.

#### Reverse-CI for packages

Nanosoldier.jl also supports testing for regression introduced by *package changes*. This
feature is currently only enabled on select repositories (contact @maleadt if you think this
is valuable for your package).

The interface for testing package changes is identical to testing Julia changes: just invoke
Nanosoldier by commenting with an appropriate trigger phrase on a commit, issue or pull
request on a package repository. The execution cycle is slightly different:

- The Julia version will be the same for both sides of the comparison, defaulting to
  `stable` (which can be customized by setting the `julia` argument of the respective
  `configuration`, e.g., to `"1.8"`)
- If no package selection is made, or the set of `ALL` packages is requested, Nanosoldier
  will look up the direct dependents of the package and test those.
- Tests will be run after registering the current state of the package in a temporary
  registry (implying that your `Project.toml` should contain a version bump). The `vs` side
  of the comparison will use an unmodified version of the registry.


## Acknowledgements

The development of the Nanosoldier benchmarking platform was supported in part by the US
Army Research Office through the Institute for Soldier Nanotechnologies under Contract
No. W911NF-07-D0004.
