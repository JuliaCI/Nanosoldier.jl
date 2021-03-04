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

function branchref(config::Config, reponame::AbstractString, branchname::AbstractString)
    shastr = GitHub.branch(reponame, branchname; auth=config.auth).commit.sha
    return BuildRef(reponame, shastr)
end

function tagref(config::Config, reponame::AbstractString, tagname::AbstractString)
    shastr = GitHub.tag(reponame, tagname; auth=config.auth).object["sha"]
    return BuildRef(reponame, shastr)
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
