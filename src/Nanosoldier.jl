module Nanosoldier

using Dates, Distributed, Printf, InteractiveUtils, Pidfile, Scratch
import GitHub, BenchmarkTools, JSON, HTTP, AWS
using Git: git
using Tar, CodecZstd

AWS.@service S3

const SHA_SEPARATOR = '@'
const BRANCH_SEPARATOR = ':'
const TAG_SEPARATOR = '#'
const SPECIAL_SELF = "%self"

include("error.jl")
include("config.jl")
include("build.jl")
include("submission.jl")
include("jobs/jobs.jl")
include("server.jl")
include("utils.jl")

workdir = ""
function __init__()
    global workdir = @get_scratch!("workdir")
end

end
