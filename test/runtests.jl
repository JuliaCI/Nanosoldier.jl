import GitHub
using Nanosoldier, Base.Test, Compat, BenchmarkTools
using Nanosoldier: BuildRef, JobSubmission, Config, BenchmarkJob
using BenchmarkTools: TrialEstimate, Parameters

##############################
# Markdown Report Generation #
##############################

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

primary = BuildRef("jrevels/julia", "25c3659d6cec2ebf6e6c7d16b03adac76a47b42a", vinfo, "")
against = Nullable(BuildRef("JuliaLang/julia", "bb73f3489d837e3339fce2c1aab283d3b2e97a4c", vinfo*"_against", ""))
config = Config("user", [1], [1], GitHub.AnonymousAuth(), "test");

function build_test_submission(tagpred; vs = "", flags = "")
    if isempty(flags) && isempty(vs)
        phrase_match = "@nanosoldier `runbenchmarks($(tagpred))`"
    elseif !(isempty(vs)) && !(isempty(flags))
        phrase_match = "@nanosoldier `runbenchmarks($(tagpred); flags = $(flags), vs = $(vs))`"
    elseif !(isempty(vs))
        phrase_match = "@nanosoldier `runbenchmarks($(tagpred); vs = $(vs))`"
    elseif !(isempty(flags))
        phrase_match = "@nanosoldier `runbenchmarks($(tagpred); flags = $(flags))`"
    end
    func, args, kwargs = Nanosoldier.parse_phrase_match(phrase_match)
    submission = JobSubmission(config, primary, "https://www.test.com", :commit, Nullable{Int}(), func, args, kwargs)
    @test submission.build.flags == flags
    @test Nanosoldier.isvalid(submission, BenchmarkJob)
    return submission
end

build_test_submission("ALL", vs = "\"JuliaLang/julia:master\"")
build_test_submission("\"tag\"")

tagpred = "ALL && !(\"tag1\" || \"tag2\")"
sub = build_test_submission(tagpred, flags = "\"-j 4\"")
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
    mdpath = joinpath(Pkg.dir("Nanosoldier"), "test", "report.md")
    open(mdpath, "r") do file
        readstring(file) == sprint(io -> Nanosoldier.printreport(io, job, results))
    end
end
