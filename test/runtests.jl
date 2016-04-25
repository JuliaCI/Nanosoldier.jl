print("Testing BenchmarkJob...")
tic()
include("BenchmarkJobTest.jl")
println("done (took $(toq()) seconds)")
