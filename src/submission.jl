
type JobSubmission
    config::Config
    build::BuildRef
    url::UTF8String         # the URL linking to the triggering comment
    fromkind::Symbol        # `:pr`, `:review`, or `:commit`?
    prnumber::Nullable{Int} # the job's PR number, if `fromkind` is `:pr` or `:review`
    func::UTF8String
    args::Vector{UTF8String}
    kwargs::Dict{Symbol,UTF8String}
    function JobSubmission(config, build, url, fromkind, prnumber, func, args, kwargs)
        if haskey(kwargs, :flags)
            build.flags = kwargs[:flags]
            delete!(kwargs, :flags)
        end
        return new(config, build, url, fromkind, prnumber, func, args, kwargs)
    end
end

function JobSubmission(config::Config, event::GitHub.WebhookEvent, phrase::RegexMatch)
    build, url, fromkind, prnumber = parse_event(config, event)
    try
        func, args, kwargs = parse_phrase_match(phrase.match)
    catch err
        error("could not parse trigger phrase: $err")
    end
    return JobSubmission(config, build, url, fromkind, prnumber, func, args, kwargs)
end

function Base.(:(==))(a::JobSubmission, b::JobSubmission)
    if isnull(a.prnumber) == isnull(b.prnumber)
        same_prnumber = isnull(a.prnumber) ? true : (get(a.prnumber) == get(b.prnumber))
        return (same_prnumber && a.config == b.config && a.build == b.build &&
                a.url == b.url && a.fromkind == b.fromkind &&
                a.func == b.func && a.args == b.args)
    else
        return false
    end
end

function parse_event(config::Config, event::GitHub.WebhookEvent)
    if event.kind == "commit_comment"
        # A commit was commented on, and the comment contained a trigger phrase.
        # The primary repo is the location of the comment, and the primary SHA
        # is that of the commit that was commented on.
        repo = get(event.repository.full_name)
        sha = event.payload["comment"]["commit_id"]
        url = event.payload["comment"]["html_url"]
        fromkind = :commit
        prnumber = Nullable{Int}()
    elseif event.kind == "pull_request_review_comment"
        # A diff was commented on, and the comment contained a trigger phrase.
        # The primary repo is the location of the head branch, and the primary
        # SHA is that of the commit associated with the diff.
        repo = event.payload["pull_request"]["head"]["repo"]["full_name"]
        sha = event.payload["comment"]["commit_id"]
        url = event.payload["comment"]["html_url"]
        fromkind = :review
        prnumber = Nullable(Int(event.payload["pull_request"]["number"]))
    elseif event.kind == "pull_request"
        # A PR was opened, and the description body contained a trigger phrase.
        # The primary repo is the location of the head branch, and the primary
        # SHA is that of the head commit. The PR number is provided, so that the
        # build can execute on the relevant merge commit.
        repo = event.payload["pull_request"]["head"]["repo"]["full_name"]
        sha = event.payload["pull_request"]["head"]["sha"]
        url = event.payload["pull_request"]["html_url"]
        fromkind = :pr
        prnumber = Nullable(Int(event.payload["pull_request"]["number"]))
    elseif event.kind == "issue_comment"
        # A comment was made in a PR, and it contained a trigger phrase. The
        # primary repo is the location of the PR's head branch, and the primary
        # SHA is that of the head commit. The PR number is provided, so that the
        # build can execute on the relevant merge commit.
        pr = GitHub.pull_request(event.repository, event.payload["issue"]["number"], auth = config.auth)
        repo = get(get(get(pr.head).repo).full_name)
        sha = get(get(pr.head).sha)
        url = event.payload["comment"]["html_url"]
        fromkind = :pr
        prnumber = Nullable(Int(get(pr.number)))
    end
    return BuildRef(repo, sha), url, fromkind, prnumber
end

function parse_phrase_match(phrase_match::AbstractString)
    fncall = match(r"`.*?`", phrase_match).match[2:end-1]
    argind = searchindex(fncall, "(")
    name = fncall[1:(argind - 1)]
    argsexpr = parse(replace(fncall[argind:end], ";", ","))
    @assert argsexpr.head == :tuple "invalid argument format"
    args, kwargs = Vector{UTF8String}(), Dict{Symbol,UTF8String}()
    started_kwargs = false
    for x in argsexpr.args
        if isa(x, Expr)
            if (x.head == :kw || x.head == :(=)) && isa(x.args[1], Symbol)
                kwargs[x.args[1]] = UTF8String(repr(x.args[2]))
                started_kwargs = true
            else
                @assert !(started_kwargs) "kwargs must come after other args"
                push!(args, UTF8String(string(x)))
            end
        else
            @assert !(started_kwargs) "kwargs must come after other args"
            push!(args, UTF8String(repr(x)))
        end
    end
    return name, args, kwargs
end

function reply_status(sub::JobSubmission, state, description, url=nothing)
    params = Dict("state" => state,
                  "context" => "Nanosoldier",
                  "description" => snip(description, 140))
    url != nothing && (params["target_url"] = url)
    return GitHub.create_status(sub.config.trackrepo, sub.build.sha;
                                auth = sub.config.auth, params = params)
end

function reply_comment(sub::JobSubmission, message::AbstractString)
    commentplace = isnull(sub.prnumber) ? sub.build.sha : get(sub.prnumber)
    commentkind = sub.fromkind == :review ? :pr : sub.fromkind
    return GitHub.create_comment(sub.build.repo, commentplace, commentkind;
                                 auth = sub.config.auth, params = Dict("body" => message))
end

function upload_report_file(sub::JobSubmission, path, content, message)
    cfg = sub.config
    params = Dict("content" => content, "message" => message)
    # An HTTP response code of 400 means the file doesn't exist, which will cause the
    # returned `GitHub.Content` object to contain a null `sha` field. We set `handle_error`
    # to false so that GitHub.jl doesn't throw an error in the case of a 400 response code.
    priorfile = GitHub.file(cfg.reportrepo, path; auth = cfg.auth, handle_error = false)
    if isnull(priorfile.sha)
        results = GitHub.create_file(cfg.reportrepo, path; auth = cfg.auth, params = params)
    else
        params["sha"] = get(priorfile.sha)
        results = GitHub.update_file(cfg.reportrepo, path; auth = cfg.auth, params = params)
    end
    return string(GitHub.permalink(results["content"], results["commit"]))
end
