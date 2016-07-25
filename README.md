# Nanosoldier.jl

[![Build Status](https://travis-ci.org/JuliaCI/Nanosoldier.jl.svg?branch=master)](https://travis-ci.org/JuliaCI/Nanosoldier.jl)

This package contains the infrastructure powering the @nanosoldier CI bot used by the Julia language.

## Submitting CI jobs via comments

If you're a collaborator in the JuliaLang/julia repository, you can submit CI jobs to the Julia Lab's Nanosoldier cluster at MIT by commenting on commits or pull requests. The @nanosoldier bot looks for a special "trigger phrase" in your comment, and if the trigger phrase is found, it is parsed by the bot to configure and submit a CI job.

The trigger phrase syntax is:

```
@nanosoldier `command(args..., kwargs...)`
```

Here's an example of a comment that might trigger a benchmarking job from a commit:

```
Let's see whether the commit I'm commenting on is faster than the master branch for the linear algebra benchmarks:

@nanosoldier `runbenchmarks("linalg", vs = ":master")`
```

When a job is completed, @nanosoldier will reply to your comment to tell you how the job went and link you to any relevant results.

**Note that only one job can be triggered per comment.**

## Available job types

CI jobs are implemented in this package as subtypes of `Nanosoldier.AbstractJob`. See [here](https://github.com/JuliaCI/Nanosoldier.jl/blob/master/src/jobs/jobs.jl) for a description of the interface new job types need to implement.

#### `BenchmarkJob`

##### Execution Cycle

A `BenchmarkJob` has the following execution cycle:

1. Pull in the JuliaLang/julia repository and build the commit specified by the context of the trigger phrase.
2. Using the new Julia build, fetch the `nanosoldier` branch of the [BaseBenchmarks](https://github.com/JuliaCI/BaseBenchmarks.jl) repository and run the benchmarks specified by the trigger phrase.
3. If the trigger phrase specifies a commit to compare against, build that version of Julia and perform step 2 using the comparison build.
4. Upload a markdown report to the [BaseBenchmarkReports](https://github.com/JuliaCI/BaseBenchmarkReports) repository.

##### Trigger Syntax

A `BenchmarkJob` is triggered with the following syntax:

```
@nanosoldier `runbenchmarks(tag_predicate, vs = "ref")`
```

The `vs` keyword argument is optional, and is used to determine whether or not the comparison step (step 3 above) is performed.

The tag predicate is used to decide which benchmarks to run, and supports the syntax defined by the [tagging system](https://github.com/JuliaCI/BenchmarkTools.jl/blob/master/doc/manual.md#indexing-into-a-benchmarkgroup-using-tagged) implemented in the [BenchmarkTools](https://github.com/JuliaCI/BenchmarkTools.jl) package. Additionally, you can run all benchmarks by using the keyword `ALL`, e.g. `runbenchmarks(ALL)`.

The `vs` keyword argument takes a reference string which can points to a Julia commit to compare against. The following syntax is supported for reference string:

- `":branch"`: the head commit of the branch named `branch` in the current repository (`JuliaLang/julia`)
- `"@sha"`: the commit specified by `sha` in the current repository (`JuliaLang/julia`)
- `"owner/repo:branch"`: the head commit of the branch named `branch` in the repository `owner/repo`
- `"owner/repo@sha"`: the commit specified by `sha` in the repository `owner/repo`

##### Benchmark Results

Once a `BenchmarkJob` is complete, the results are uploaded to the
[BaseBenchmarkReports](https://github.com/JuliaCI/BaseBenchmarkReports) repository. Each job
has its own directory for results. This directory contains the following items:

- `report.md` is a markdown report that summarizes the job results
- `data.tar.gz` contains raw timing data in JLD format. To untar this file, run
`tar -xzvf data.tar.gz`. You can analyze this data using the
[BenchmarkTools](https://github.com/JuliaCI/BaseBenchmarkReports) package.
- `logs` is a directory containing the build logs and benchmark execution logs for the job.

##### Comment Examples

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

@nanosoldier `runbenchmarks(ALL, vs = "jrevels/julia@c70ab26bb677c92f0d8e0ae41c3035217a4b111f")`
```

```
I want to run all benchmarks on the current commit. I want to compare the results
against the head commit of my fork's branch.

@nanosoldier `runbenchmarks(ALL, vs = "jrevels/julia:mybranch")`
```
