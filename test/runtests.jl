import GitHub
using Nanosoldier, Test, BenchmarkTools
using Nanosoldier: BuildRef, JobSubmission, Config, BenchmarkJob, PkgEvalJob, AbstractJob
using BenchmarkTools: TrialEstimate, Parameters
using DataFrames

#########
# setup #
#########

ENV["NANOSOLDIER_DRYRUN"] = true

vinfo = """
Julia Version 0.4.3-pre+6
Commit adffe19 (2015-12-11 00:38 UTC)
Platform Info:
  System: Darwin (x86_64-apple-darwin13.4.0)
  CPU: Intel(R) Core(TM) i5-4288U CPU @ 2.60GHz
  WORD_SIZE: 64
  uname: Darwin 13.4.0 Darwin Kernel Version 13.4.0: Wed Dec 17 19:05:52 PST 2014; root:xnu-2422.115.10~1/RELEASE_X86_64 x86_64 i386
Memory: 8.0 GB (1025.07421875 MB free)
Uptime: 646189.0 sec
Load Avg:  1.38427734375  1.416015625  1.41455078125
Intel(R) Core(TM) i5-4288U CPU @ 2.60GHz:
       speed         user         nice          sys         idle          irq
#1  2600 MHz     186848 s          0 s     114241 s    1462955 s          0 s
#2  2600 MHz     114716 s          0 s      43882 s    1605408 s          0 s
#3  2600 MHz     189864 s          0 s      77629 s    1496513 s          0 s
#4  2600 MHz     114652 s          0 s      42497 s    1606856 s          0 s

  BLAS: libopenblas (USE64BITINT DYNAMIC_ARCH NO_AFFINITY Haswell)
  LAPACK: libopenblas64_
  LIBM: libopenlibm
  LLVM: libLLVM-3.3
"""
auth = if haskey(ENV, "GITHUB_AUTH")
    GitHub.authenticate(ENV["GITHUB_AUTH"])
else
    GitHub.AnonymousAuth()
end
primary_commit = GitHub.commits("JuliaLang/julia"; auth, page_limit=1)[1][10].sha
against_commit = GitHub.commits("JuliaLang/julia"; auth, page_limit=1)[1][11].sha
primary = BuildRef("JuliaLang/julia", primary_commit, vinfo)
against = BuildRef("JuliaLang/julia", against_commit, vinfo*"_against")
config = Config("user", Dict(Any => [getpid()]), auth, "test", trackrepo=primary.repo);
tagpred = "ALL && !(\"tag1\" || \"tag2\")"
pkgsel = "[\"Example\"]"

#####################################
# submission parsing and validation #
#####################################

function build_test_submission(jobtyp, submission_string)
    func, args, kwargs = Nanosoldier.parse_submission_string(submission_string)
    submission = JobSubmission(config, primary, primary.sha, "https://www.test.com", :commit, nothing, func, args, kwargs)
    @test Nanosoldier.isvalid(submission, jobtyp)
    return jobtyp(submission)
end

job = build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(ALL)`")
@test job.against === nothing
build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(\"tag\")`")
build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks($tagpred)`")

job = build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(ALL, vs = \"JuliaLang/julia:master\")`")
@test job.against !== nothing
build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(\"tag\", vs = \"JuliaLang/julia:master\")`")
build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks($tagpred, vs = \"JuliaLang/julia:master\")`")

job = build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(ALL, vs = \"%self\")`")
@test job.against == primary
build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(\"tag\", vs = \"%self\")`")
build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks($tagpred, vs = \"%self\")`")

@test_throws ErrorException("invalid commit to run isdaily") build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(ALL, isdaily = true, vs = \"JuliaLang/julia:master\")`")
@test_throws ErrorException("invalid commit to run isdaily") build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(\"tag\", isdaily = true, vs = \"JuliaLang/julia:master\")`")
@test_throws ErrorException("invalid commit to run isdaily") build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks($tagpred, isdaily = true, vs = \"JuliaLang/julia:master\")`")

@test_throws ErrorException("invalid commit to run isdaily") build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(ALL; isdaily = true, vs = \"JuliaLang/julia:master\")`")
@test_throws ErrorException("invalid commit to run isdaily") build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(\"tag\"; isdaily = true, vs = \"JuliaLang/julia:master\")`")
@test_throws ErrorException("invalid commit to run isdaily") build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks($tagpred; isdaily = true, vs = \"JuliaLang/julia:master\")`")

job = build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(ALL, vs = \"JuliaLang/julia#v1.0.0\")`")
@test job.against !== nothing
build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(\"tag\", vs = \"JuliaLang/julia#v1.0.0\")`")
build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks($tagpred, vs = \"JuliaLang/julia#v1.0.0\")`")

job = build_test_submission(PkgEvalJob, "@nanosoldier `runtests(ALL)`")
@test job.against === nothing
build_test_submission(PkgEvalJob, "@nanosoldier `runtests(\"pkg\")`")
build_test_submission(PkgEvalJob, "@nanosoldier `runtests($pkgsel)`")

job = build_test_submission(PkgEvalJob, "@nanosoldier `runtests($pkgsel)`")
@test !job.configuration.compiled
job = build_test_submission(PkgEvalJob, "@nanosoldier `runtests($pkgsel, configuration=(compiled=true, ))`")
@test job.configuration.compiled
job = build_test_submission(PkgEvalJob, "@nanosoldier `runtests($pkgsel, configuration=(buildflags=[\"FOO=BAR\"], ))`")
@test job.configuration.buildflags == ["FOO=BAR"]

#############################
# retrieval from job queue  #
#############################

non_daily_job = build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(ALL)`")
daily_job = build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks(ALL, isdaily = true)`")

queue = [daily_job, daily_job]
job = Nanosoldier.retrieve_job!(queue, BenchmarkJob, true)
@test job !== nothing && job.isdaily
@test length(queue) == 1

queue = [non_daily_job, daily_job]
job = Nanosoldier.retrieve_job!(queue, BenchmarkJob, true)
@test job !== nothing && !job.isdaily
@test length(queue) == 1

queue = [daily_job, non_daily_job]
job = Nanosoldier.retrieve_job!(queue, BenchmarkJob, true)
@test job !== nothing && job.isdaily
@test length(queue) == 1

queue = [daily_job, daily_job]
job = Nanosoldier.retrieve_job!(queue, BenchmarkJob, false)
@test job === nothing
@test length(queue) == 2

queue = [non_daily_job, daily_job]
job = Nanosoldier.retrieve_job!(queue, BenchmarkJob, false)
@test job !== nothing && !job.isdaily
@test length(queue) == 1

queue = [daily_job, non_daily_job]
job = Nanosoldier.retrieve_job!(queue, BenchmarkJob, false)
@test job !== nothing && !job.isdaily
@test length(queue) == 1

queue = [daily_job, non_daily_job]
job = Nanosoldier.retrieve_job!(queue, PkgEvalJob, true)
@test job === nothing
@test length(queue) == 2

queue = [daily_job, non_daily_job]
job = Nanosoldier.retrieve_job!(queue, BenchmarkJob, true)
@test job !== nothing && job.isdaily
@test length(queue) == 1

queue = [daily_job, non_daily_job]
job = Nanosoldier.retrieve_job!(queue, Any, false)
@test job !== nothing && !job.isdaily
@test length(queue) == 1

#########################
# job report generation #
#########################

job = build_test_submission(BenchmarkJob, "@nanosoldier `runbenchmarks($tagpred)`")
@test job.tagpred == tagpred
@test job.against === nothing
job.against = against

results = Dict(
    "primary" => BenchmarkGroup([],
        "g" => BenchmarkGroup([],
            "h" => BenchmarkGroup([],
                "x"      => TrialEstimate(Parameters(), 1.0, 3.5, 1.0, 1.0),  # invariant
                ("y", 1) => TrialEstimate(Parameters(memory_tolerance = 0.03), 2.0, 1.0, 0.0, 1.0),  # regression/improvement
                ("y", 2) => TrialEstimate(Parameters(time_tolerance = 0.04), 0.5, 1.0, 1.0, 1.0),  # improvement
                "z"      => TrialEstimate(Parameters(memory_tolerance = 0.27, time_tolerance = 0.6), 1.0, 1.0, 5.0, 1.0),  # regression
                "∅"      => TrialEstimate(Parameters(), 1.0, 1.0, 1.0, 1.0) # not in "against" group
            )
        )
    ),
    "against" => BenchmarkGroup([],
        "g" => BenchmarkGroup([],
            "h" => BenchmarkGroup([],
                "x"      => TrialEstimate(Parameters(), 1.0, 1.0, 1.0, 1.0),
                ("y", 1) => TrialEstimate(Parameters(), 1.0, 1.0, 1.0, 1.0),
                ("y", 2) => TrialEstimate(Parameters(), 1.0, 1.0, 1.0, 1.0),
                "z"      => TrialEstimate(Parameters(), 1.0, 1.0, 1.0, 1.0)
            )
        )
    )
)

results["judged"] = BenchmarkTools.judge(results["primary"], results["against"])

@test begin
    mdpath = joinpath(@__DIR__, "report.md")
    md = replace(read(mdpath, String), "PRIMARY" => primary_commit, "AGAINST" => against_commit)
    md2 = sprint(io->Nanosoldier.printreport(io, job, results))
    chomp.(eachline(IOBuffer(md))) == chomp.(eachline(IOBuffer(md2)))
end

@testset "Markdown" begin
    @test Nanosoldier.markdown_escaped("abc") == "abc"
    @test Nanosoldier.markdown_escaped(raw"a\`*_#+-.!{}[]()<>|b") == raw"a\\\`\*\_\#\+\-\.\!\{\}\[\]\(\)\<\>\|b"

    @test Nanosoldier.markdown_escaped_code("abc") == "`abc`"
    @test Nanosoldier.markdown_escaped_code("a`b`c") == "``a`b`c``"
    @test Nanosoldier.markdown_escaped_code("``ab`c") == "``` ``ab`c```"
    @test Nanosoldier.markdown_escaped_code("a`bc```") == "````a`bc``` ````"
end


@testset "PkgEvalJob" begin
    job = build_test_submission(PkgEvalJob, "@nanosoldier `runtests($pkgsel)`")
    @test job.against === nothing

    results = Dict{String,Any}(
        "primary" => DataFrame(
            configuration="primary",
            package="Example",
            version=v"0.1.0",
            status=:ok,
            reason=missing,
            duration=0.0,
            log="everything is fine",
        )
    )

    report = sprint(io -> Nanosoldier.printreport(io, job, results))

    job.against = against
    results["against"] = DataFrame(
            configuration="against",
            package="Example",
            version=v"0.1.0",
            status=:fail,
            reason=:test_failures,
            duration=0.0,
            log="this one failed",
        )

    report = sprint(io -> Nanosoldier.printreport(io, job, results))
end


##################
# actual testing #
##################

job = build_test_submission(PkgEvalJob, "@nanosoldier `runtests($pkgsel, vs=\"@$against_commit\")`")
run(job)

nothing
