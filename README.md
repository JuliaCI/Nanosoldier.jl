# Nanosoldier.jl

[![Build Status](https://travis-ci.org/JuliaCI/Nanosoldier.jl.svg?branch=master)](https://travis-ci.org/JuliaCI/Nanosoldier.jl)

This package contains the infrastructure powering the @nanosoldier CI bot used by the Julia language.

## Quick start

If you're a collaborator in the JuliaLang/julia repository, you can submit CI jobs to the Julia Lab's Nanosoldier cluster at MIT by commenting on commits or pull requests. The @nanosoldier bot looks for a special "trigger phrase" in your comment, and if the trigger phrase is found, it is parsed by the bot to configure and submit a CI job.

The trigger phrase syntax is:

```
@nanosoldier `command(args..., kwargs...)`
```

Backticks are mandatory. There are two kinds of jobs you can invoke: **benchmark jobs**, which run the [BaseBenchmarks.jl](https://github.com/JuliaCI/BaseBenchmarks.jl) suite, and **package test jobs** which rely on [PkgEval.jl](https://github.com/JuliaCI/PkgEval.jl) to run the test suite of all registered packages.

**Note that only one job can be triggered per comment.**

One of the most common invocations runs all benchmarks on your PR, comparing against the current Julia master branch:

```
@nanosoldier `runbenchmarks(ALL, vs=":master")`
```

Similarly, you can run all package tests, e.g. if you suspect your PR might be breaking:

```
@nanosoldier `runtests(ALL, vs = ":master")`
```

Both operations take a long time, so it might be wise to restrict which benchmarks you want to run, or which packages you want to test:

```
@nanosoldier `runbenchmarks("linalg", vs = ":master")`

@nanosoldier `runtests(["JSON", "Crayons"], vs = ":master")`
```

When a job is completed, @nanosoldier will reply to your comment to tell you how the job went and link you to any relevant results.


## Available job types

CI jobs are implemented in this package as subtypes of `Nanosoldier.AbstractJob`. See [here](https://github.com/JuliaCI/Nanosoldier.jl/blob/master/src/jobs/jobs.jl) for a description of the interface new job types need to implement.

### `BenchmarkJob`

#### Execution Cycle

A `BenchmarkJob` has the following execution cycle:

1. Pull in the JuliaLang/julia repository and build the commit specified by the context of the trigger phrase.
2. Using the new Julia build, fetch the `nanosoldier` branch of the [BaseBenchmarks](https://github.com/JuliaCI/BaseBenchmarks.jl) repository and run the benchmarks specified by the trigger phrase.
3. If the trigger phrase specifies a commit to compare against, build that version of Julia and perform step 2 using the comparison build.
4. Upload a markdown report to the [NanosoldierReports](https://github.com/JuliaCI/NanosoldierReports) repository.

#### Trigger Syntax

A `BenchmarkJob` is triggered with the following syntax:

```
@nanosoldier `runbenchmarks(tag_predicate, vs = "ref")`
```

The `vs` keyword argument is optional, and is used to determine whether or not the comparison step (step 3 above) is performed.

The tag predicate is used to decide which benchmarks to run, and supports the syntax defined by the [tagging system](https://github.com/JuliaCI/BenchmarkTools.jl/blob/master/doc/manual.md#indexing-into-a-benchmarkgroup-using-tagged) implemented in the [BenchmarkTools](https://github.com/JuliaCI/BenchmarkTools.jl) package. Additionally, you can run all benchmarks by using the keyword `ALL`, e.g. `runbenchmarks(ALL)`.

The `vs` keyword argument takes a reference string which can points to a Julia commit to compare against. The following syntax is supported for reference string:

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

@nanosoldier `runbenchmarks(ALL, vs = "christopher-dG/julia@c70ab26bb677c92f0d8e0ae41c3035217a4b111f")`
```

```
I want to run all benchmarks on the current commit. I want to compare the results
against the head commit of my fork's branch.

@nanosoldier `runbenchmarks(ALL, vs = "christopher-dG/julia:mybranch")`
```

### `PkgEvalJob`

#### Execution Cycle

A `PkgEvalJob` has the following execution cycle:

1. Pull in the JuliaLang/julia repository and build the commit specified by the context of the trigger phrase.
2. Using the new Julia build, test the packages from the [General](https://github.com/JuliaRegistries/General) registry as specified by the trigger phrase.
3. If the trigger phrase specifies a commit to compare against, build that version of Julia and perform step 2 using the comparison build.
4. Upload a markdown report to the [NanosoldierReports](https://github.com/JuliaCI/NanosoldierReports) repository.

#### Trigger Syntax

A `PkgEvalJob` is triggered with the following syntax:

```
@nanosoldier `runtests(package_selection, vs = "ref")`
```

The package selection argument is used to decide which packages to test. It should be a list of package names, e.g. `["Example"]`, that will be looked up in the registry. Additionally, you can test all packages in the registry by using the keyword `ALL`, e.g. `runtests(ALL)`.

The `vs` keyword argument is optional, and is used to determine whether or not the comparison step (step 3 above) is performed. Its syntax is identical to the `BenchmarkJob` `vs` keyword argument.

Both sides of the comparison can be further configured by using respectively the `configuration` and `vs_configuration` arguments. These options expect a named tuple where the elements correspond to fields of the `PkgEval.Configuration` type.

For example, a common configuration is to include buildflags that enable assertions:

```
@nanosoldier `runtests(ALL, vs = "%self", configuration = (buildflags=["LLVM_ASSERTIONS=1", "FORCE_ASSERTIONS=1"],))`
```

Another useful example makes PkgEval run under rr and use a Julia debug build for a better debugging experience:

```
@nanosoldier `runtests(ALL, configuration = (buildflags=["JULIA_BUILD_MODE=debug"], julia_binary="julia-debug", rr=true))`
```

If no configuration arguments are specified, the primary build will use `rr=true`, but other than that the defaults as specified by the `PkgEval.Configuration` constructor are used.

#### Results

Once a `PkgEvalJob` is complete, the results are uploaded to the
[NanosoldierReports](https://github.com/JuliaCI/NanosoldierReports) repository. Each job
has its own directory for results. This directory contains the following items:

- `report.md` is a markdown report that summarizes the job results
- `data.tar.xz` contains raw test data as Feather files encoding a DataFrame. To untar this file, run
`tar -xvf data.tar.xz`.

In addition, a rendered version of the report as well as the logs for each package are uploaded to AWS, and will be posted as a reply on GitHub where the job was invoked.

## Initial Setup for BenchmarksJob

On all computers:
```
echo "if this is a shared machine, you must use a password to secure this:"
[ -f ~/.ssh/id_rsa ] || ssh-keygen -f ~/.ssh/id_rsa
echo "add to https://github.com/settings/keys:"
cat ~/.ssh/id_rsa.pub
EDITOR=vim git config --global --edit
sudo mkdir /nanosoldier
sudo chown `whoami` /nanosoldier
cd /nanosoldier
git clone <URL>
cd ./Nanosoldier.jl
git checkout <branch>
./provision-<worker|server>.sh
```

On main server:
```
scp ~nanosoldier/.ssh/id_rsa ~nanosoldier/.ssh/id_rsa.pub <workers>:
ssh -t <workers> sudo chown nanosoldier:nanosoldier id_rsa id_rsa.pub
ssh -t <workers> sudo mv id_rsa id_rsa.pub ~nanosoldier/.ssh
ssh -t <workers> sudo -u nanosoldier cat .ssh/id_rsa.pub >> .ssh/authorized_keys
ssh -t <workers> sudo -u nanosoldier "bash -c 'cat ~nanosoldier/.ssh/id_rsa.pub >> ~nanosoldier/.ssh/authorized_keys'"
sudo -u nanosoldier ssh <workers> exit
# repeat above for every worker, then:
sudo -u nanosoldier scp ~nanosoldier/.ssh/known_hosts <workers>:.ssh
```

To run:

```
cd /nanosoldier/Nanosoldier.jl
byobu
./run_base_ci
```

## Upgrading for BenchmarksJob

# on server
```
cd /nanosoldier/Nanosoldier.jl
git pull
chmod 666 *.toml
sudo -u nanosoldier ../julia-1.6.6/bin/julia --project=. -e 'using Pkg; Pkg.update()'
chmod 664 *.toml
./provision-server.sh
git add -u
git commit
git push
```

# on each worker
```
cd /nanosoldier/Nanosoldier.jl
git pull
./provision-worker.sh
```


## Acknowledgements

The development of the Nanosoldier benchmarking platform was supported in part by the US
Army Research Office through the Institute for Soldier Nanotechnologies under Contract
No. W911NF-07-D0004.
