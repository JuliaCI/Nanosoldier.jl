module Nanosoldier

using Dates, Distributed, Printf, InteractiveUtils
import GitHub, BenchmarkTools, JSON, HTTP, AWS

AWS.@service S3

const SHA_SEPARATOR = '@'
const BRANCH_SEPARATOR = ':'
const TAG_SEPARATOR = '#'

#####################
# utility functions #
#####################

snip(str, len) = str[1:min(len, end)]
snipsha(sha) = snip(sha, 7)

function gitclone!(repo, path, auth=nothing)
    if isa(auth, GitHub.OAuth2)
        run(`git clone https://$(auth.token):x-oauth-basic@github.com/$(repo).git $(path)`)
    elseif isa(auth, GitHub.UsernamePassAuth)
        run(`git clone https://$(auth.username):$(auth.password)@github.com/$(repo).git $(path)`)
    else
        run(`git clone git@github.com:$(repo).git $(path)`)
    end
end

gitreset!() = (run(`git fetch --all`); run(`git reset --hard origin/master`))
gitreset!(path) = cd(gitreset!, path)

##################
# error handling #
##################

mutable struct NanosoldierError{E<:Exception} <: Exception
    url::String
    msg::String
    err::E
end

NanosoldierError(msg, err::E) where {E<:Exception} = NanosoldierError{E}("", msg, err)

function Base.show(io::IO, err::NanosoldierError)
    print(io, "NanosoldierError: ", err.msg, ": ")
    showerror(io, err.err)
end

############
# includes #
############

include("config.jl")
include("build.jl")
include("submission.jl")
include("jobs/jobs.jl")
include("server.jl")

end # module
