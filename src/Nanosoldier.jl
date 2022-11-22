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

workdir = ""

#####################
# utility functions #
#####################

snip(str, len) = str[1:min(len, end)]
snipsha(sha) = snip(sha, 7)

sudo(cmd::Cmd) = sudo(`-n`, cmd)
sudo(user::String, cmd::Cmd) = sudo(`-n -u $user`, cmd)
function sudo(args::Cmd, cmd::Cmd)
    # non-default environment behavior is only permitted for the first interpolant,
    # so we need to splice the command's environment into the sudo invocation.
    dir = cmd.dir
    env = something(cmd.env, [])
    cmd = Cmd(cmd; env=nothing, dir="")
    setenv(`sudo $args $env -- $cmd`; dir)
end

function gitclone!(repo, dir, auth=nothing, args::Cmd=``; user=nothing)
    if isa(auth, GitHub.OAuth2)
        url = "https://$(auth.token):x-oauth-basic@github.com/"
    elseif isa(auth, GitHub.UsernamePassAuth)
        url = "https://$(auth.username):$(auth.password)@github.com/"
    else
        auth = auth::Nothing
        url = "https://github.com/"
    end
    if user === nothing
        if auth !== nothing
            run(`mkdir -p -m 770 $dir`)
        end
        run(`$(git()) clone --quiet $args $url$repo.git $dir`)
    else
        if auth !== nothing
            run(sudo(`-n -u $user`, `mkdir -p -m 770 $dir`))
        end
        run(sudo(`-n -u $user`, `$(git()) clone $args $url$repo.git $dir`))
    end
end
gitclone!(repo, dir, args::Cmd; user=nothing) = gitclone!(repo, dir, nothing, args; user)

function gitreset!(dir)
    run(`$(git()) -C $dir fetch --quiet --all`)
    run(`$(git()) -C $dir reset --quiet --hard origin/master`)
end

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

function __init__()
    global workdir = @get_scratch!("workdir")
end

end # module
