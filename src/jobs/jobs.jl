# All types `J <: AbstractJob` must implement:
#
# - `J(submission::JobSubmission)`: create an instance of `J` from `submission`
# - `submission(job::J)`: return the `JobSubmission` used to create `job`
# - `isvalid(submission::JobSubmission, ::Type{J})`: return true if `submission` is a valid input for `J`, false otherwise
# - `Base.run(job::J)`: execute `job`
# - `Base.summary(job::J)`: a short string identifying/describing `job`

abstract type AbstractJob end

reply_status(job::AbstractJob, args...; kwargs...) = reply_status(submission(job), "Nanosoldier/$(nameof(typeof(job)))", args...; kwargs...)
reply_comment(job::AbstractJob, args...; kwargs...) = reply_comment(submission(job), args...; kwargs...)
upload_report_repo!(job::AbstractJob, args...; kwargs...) = upload_report_repo!(submission(job), args...; kwargs...)

function commitref(config::Config, reponame::AbstractString, shastr::AbstractString)
    commit = GitHub.commit(reponame, shastr; auth=config.auth)
    return BuildRef(reponame, shastr, commit.commit.committer.date)
end

function branchref(config::Config, reponame::AbstractString, branchname::AbstractString)
    commit = GitHub.branch(reponame, branchname; auth=config.auth).commit
    return BuildRef(reponame, commit.sha, commit.commit.committer.date)
end

function tagref(config::Config, reponame::AbstractString, tagname::AbstractString)
    tag = GitHub.tag(reponame, tagname; auth=config.auth)
    commitref(config, reponame, tag.object["sha"])
end

# check that isdaily is well-formed (no extra parameters, on a recent master commit, not a PR)
# and not accidentally submitted elsewhere
function validatate_isdaily(submission::JobSubmission)
    if submission.prnumber === nothing && submission.kwargs == Dict(:isdaily => "true")
        config = submission.config
        for commit in GitHub.commits(config.trackrepo; auth=config.auth, page_limit=1, params=Dict("per_page" => 50))[1]
            if commit.sha == submission.statussha
                return
            end
        end
    end
    error("invalid commit to run isdaily")
end

datedirname(date::Dates.Date) = joinpath(Dates.format(date, dateformat"yyyy-mm"),
                                         Dates.format(date, dateformat"dd"))

# Put `str` into Markdown literally
# XXX: In a table, | would instead written with &#124; instead.
#      Should we make that a bool arg to give the context?
markdown_escaped(str) = replace(str, r"[\\`*_#+-.!{}[\]()<>|]" => s"\\\0")

# Put `str` inside Markdown code marks
function markdown_escaped_code(str)
    ticks = eachmatch(r"`+", str)
    isempty(ticks) && return "`$str`"
    ticks = maximum(x -> length(x.match), ticks) + 1
    ticks = "`"^ticks
    return string(ticks, startswith(str, '`') ? " " : "", str, endswith(str, '`') ? " " : "", ticks)
end


include("BenchmarkJob.jl")
include("PkgEvalJob.jl")
