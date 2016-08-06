module Nanosoldier

import GitHub, BenchmarkTools, JLD, JSON, HttpCommon

using Compat

import Compat.UTF8String

const TRIGGER = r"\@nanosoldier\s*`.*?`"
const SHA_SEPARATOR = '@'
const BRANCH_SEPARATOR = ':'

#####################
# utility functions #
#####################

snip(str, len) = length(str) > len ? str[1:len] : str
snipsha(sha) = snip(sha, 7)

gitclone!(repo, path) = run(`git clone git@github.com:$(repo).git $(path)`)

gitreset!() = (run(`git fetch --all`); run(`git reset --hard origin/master`))
gitreset!(path) = cd(gitreset!, path)

##################
# error handling #
##################

immutable NanosoldierError{E<:Exception} <: Exception
    url::UTF8String
    msg::UTF8String
    err::E
end

NanosoldierError{E<:Exception}(msg, err::E) = NanosoldierError{E}("", msg, err)

Base.show(io::IO, err::NanosoldierError) = print(io, "NanosoldierError: ", err.msg, ": ", err.err)

############
# includes #
############

include("config.jl")
include("build.jl")
include("submission.jl")
include("jobs/jobs.jl")
include("server.jl")

end # module
