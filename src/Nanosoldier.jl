module Nanosoldier

import GitHub, BenchmarkTools, JLD, JSON, HttpCommon

using Compat

const TRIGGER = r"\@nanosoldier\s*`.*?`"
const SHA_SEPARATOR = '@'
const BRANCH_SEPARATOR = ':'

snip(str, len) = length(str) > len ? str[1:len] : str

include("config.jl")
include("build.jl")
include("submission.jl")
include("jobs/jobs.jl")
include("server.jl")

end # module
