# All types `J <: AbstractJob` must implement:
#
# - `J(submission::JobSubmission)`: create an instance of `J` from `submission`
# - `submission(job::J)`: return the `JobSubmission` used to create `job`
# - `isvalid(submission::JobSubmission, ::Type{J})`: return true if `submission` is a valid input for `J`, false otherwise
# - `Base.run(job::J)`: execute `job`
# - `Base.summary(job::J)`: a short string identifying/describing `job`

abstract type AbstractJob end

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
        for commit in GitHub.commits(submission.repo; auth=config.auth, page_limit=1,
                                     params=Dict("per_page" => 50))[1]
            if commit.sha == submission.statussha
                return
            end
        end
    end
    nanosoldier_error("invalid commit to run isdaily")
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

function upload_report_repo!(job::AbstractJob, markdownpath, message)
    if haskey(ENV, "NANOSOLDIER_DRYRUN")
        @info "Running as part of test suite, not uploading report" message

        # copy the report to a path that does not depend on the commit hash to makes it
        # easier to locate and upload as a test artifact.
        source = reportdir(job)
        target = joinpath(dirname(source), "redacted_vs_redacted")
        cp(source, target)

        return target
    end

    cfg = submission(job).config
    dir = reportdir(cfg)

    # create a detached commit
    run(`$(git()) -C $dir checkout --detach --quiet`)
    run(`$(git()) -C $dir add --all`)
    run(`$(git()) -C $dir commit --message $message --quiet`)
    sha = readchomp(`$(git()) -C $dir rev-parse HEAD`)

    # cherry-pick on top of latest master
    run(`$(git()) -C $dir checkout --quiet master`)
    gitreset!(dir)
    run(`$(git()) -C $dir cherry-pick -X ours $sha`)

    run(`$(git()) -C $dir push`)
    return "https://github.com/$(reportrepo(cfg))/blob/master/$(markdownpath)"
end

function publish_update(job::AbstractJob, state, description, url=nothing;
                        fallback::Bool=true)
    try
        context = "Nanosoldier/$(nameof(typeof(job)))"
        reply_status(submission(job), state, context, description, url)
    catch err
        # XXX: can we use the API to check if we have the necessary permissions instead?
        if fallback
            @warn "Failed to push status, replying with comment instead" exception=(err, catch_backtrace())
            if url !== nothing
                reply_comment(submission(job), "Update on [$(summary(job))]($url): $description")
            else
                reply_comment(submission(job), "Update on $(summary(job)): $description")
            end
        else
            @warn "Failed to push status" exception=(err, catch_backtrace())
        end
    end
end

include("BenchmarkJob.jl")
include("PkgEvalJob.jl")
