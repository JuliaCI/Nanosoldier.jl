import GitHub
using Nanosoldier, Base.Test, Compat, BenchmarkTools
using Nanosoldier: BuildRef, JobSubmission, Config, BenchmarkJob, AbstractJob
using BenchmarkTools: TrialEstimate, Parameters

#########
# setup #
#########

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

primary = BuildRef("jrevels/julia", "25c3659d6cec2ebf6e6c7d16b03adac76a47b42a", vinfo)
against = Nullable(BuildRef("JuliaLang/julia", "bb73f3489d837e3339fce2c1aab283d3b2e97a4c", vinfo*"_against"))
config = Config("user", [1], [1], GitHub.AnonymousAuth(), "test");
tagpred = "ALL && !(\"tag1\" || \"tag2\")"

#####################################
# submission parsing and validation #
#####################################

function build_test_submission(submission_string)
    func, args, kwargs = Nanosoldier.parse_submission_string(submission_string)
    submission = JobSubmission(config, primary, primary.sha, "https://www.test.com", :commit, Nullable{Int}(), func, args, kwargs)
    @test Nanosoldier.isvalid(submission, BenchmarkJob)
    return submission
end

build_test_submission("@nanosoldier `runbenchmarks(ALL)`")
build_test_submission("@nanosoldier `runbenchmarks(\"tag\")`")
build_test_submission("@nanosoldier `runbenchmarks($tagpred)`")

build_test_submission("@nanosoldier `runbenchmarks(ALL, vs = \"JuliaLang/julia:master\")`")
build_test_submission("@nanosoldier `runbenchmarks(\"tag\", vs = \"JuliaLang/julia:master\")`")
build_test_submission("@nanosoldier `runbenchmarks($tagpred, vs = \"JuliaLang/julia:master\")`")

build_test_submission("@nanosoldier `runbenchmarks(ALL, isdaily = true, vs = \"JuliaLang/julia:master\")`")
build_test_submission("@nanosoldier `runbenchmarks(\"tag\", isdaily = true, vs = \"JuliaLang/julia:master\")`")
build_test_submission("@nanosoldier `runbenchmarks($tagpred, isdaily = true, vs = \"JuliaLang/julia:master\")`")

build_test_submission("@nanosoldier `runbenchmarks(ALL; isdaily = true, vs = \"JuliaLang/julia:master\")`")
build_test_submission("@nanosoldier `runbenchmarks(\"tag\"; isdaily = true, vs = \"JuliaLang/julia:master\")`")
build_test_submission("@nanosoldier `runbenchmarks($tagpred; isdaily = true, vs = \"JuliaLang/julia:master\")`")

#############################
# retrieval from job queue  #
#############################

non_daily_job = BenchmarkJob(build_test_submission("@nanosoldier `runbenchmarks(ALL)`"))
daily_job = BenchmarkJob(build_test_submission("@nanosoldier `runbenchmarks(ALL, isdaily = true)`"))

queue = [daily_job, daily_job]
job = Nanosoldier.retrieve_job!(queue, true)
@test !(isnull(job)) && get(job).isdaily
@test length(queue) == 1

queue = [non_daily_job, daily_job]
job = Nanosoldier.retrieve_job!(queue, true)
@test !(isnull(job)) && !(get(job).isdaily)
@test length(queue) == 1

queue = [daily_job, non_daily_job]
job = Nanosoldier.retrieve_job!(queue, true)
@test !(isnull(job)) && get(job).isdaily
@test length(queue) == 1

queue = [daily_job, daily_job]
job = Nanosoldier.retrieve_job!(queue, false)
@test isnull(job)
@test length(queue) == 2

queue = [non_daily_job, daily_job]
job = Nanosoldier.retrieve_job!(queue, false)
@test !(isnull(job)) && !(get(job).isdaily)
@test length(queue) == 1

queue = [daily_job, non_daily_job]
job = Nanosoldier.retrieve_job!(queue, false)
@test !(isnull(job)) && !(get(job).isdaily)
@test length(queue) == 1

#########################
# job report generation #
#########################

sub = build_test_submission("@nanosoldier `runbenchmarks($tagpred)`")
job = BenchmarkJob(sub)
@test Nanosoldier.submission(job) == sub
@test job.tagpred == tagpred
@test isnull(job.against)
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
    mdpath = joinpath(dirname(@__FILE__), "report.md")
    open(mdpath, "r") do file
        readstring(file) == sprint(io -> Nanosoldier.printreport(io, job, results))
    end
end
