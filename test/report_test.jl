using Nanosoldier, Base.Test, Compat
using Nanosoldier: BuildRef, BenchmarkJob
using BenchmarkTrackers: BenchmarkRecord, Metrics, ResultNumber, GroupResults, BenchmarkGroup, Tag

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

primary = BuildRef("jrevels/julia", "25c3659d6cec2ebf6e6c7d16b03adac76a47b42a", vinfo)
against = Nullable(BuildRef("JuliaLang/julia", "bb73f3489d837e3339fce2c1aab283d3b2e97a4c", vinfo))
job = BenchmarkJob(primary, against, "\"arrays\"", primary.sha, "www.example.com", :commit, Nullable{Int}())

judge_record = BenchmarkRecord(
    Tag("mygroup") => GroupResults(BenchmarkGroup{:mygroup}(Tag[]), Dict(
            "invariant" => Metrics((:invariant, 1.01), (:invariant, 1.10), (:invariant, 1.02), (:invariant, 0.98)),
            "x" => Metrics((:invariant, 1.01), (:invariant, 1.10), (:improvement, 0.12), (:improvement, 0.52)),
            "y" => Metrics((:regression, 1.21), (:invariant, 1.05), (:invariant, 1.11), (:improvement, 0.73)),
            "z" => Metrics((:invariant, 1.11), (:regression, 3.03), (:regression, 1.76), (:improvement, 0.32))
        )
    )
)

summary_dict = Dict("judged" => judge_record)

@test begin
    mdpath = joinpath(Pkg.dir("Nanosoldier"), "test", "report.md")
    open(mdpath, "r") do file
        readstring(file) == Nanosoldier.io2string(io -> Nanosoldier.print_report(io, job, summary_dict))
    end
end
