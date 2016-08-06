
type JobSubmission
    config::Config
    build::BuildRef
    statussha::UTF8String   # the SHA to send statuses to (since `build` can mutate)
    url::UTF8String         # the URL linking to the triggering comment
    fromkind::Symbol        # `:pr`, `:review`, or `:commit`?
    prnumber::Nullable{Int} # the job's PR number, if `fromkind` is `:pr` or `:review`
    func::UTF8String
    args::Vector{UTF8String}
    kwargs::Dict{Symbol,UTF8String}
end

function JobSubmission(config::Config, event::GitHub.WebhookEvent, phrase::RegexMatch)
    try
        build, statussha, url, fromkind, prnumber = parse_event(config, event)
        func, args, kwargs = parse_phrase_match(phrase.match)
        return JobSubmission(config, build, statussha, url, fromkind, prnumber, func, args, kwargs)
    catch err
        error("could not parse comment into job submission: $err")
    end
end

function @compat(Base.:(==))(a::JobSubmission, b::JobSubmission)
    if isnull(a.prnumber) == isnull(b.prnumber)
        same_prnumber = isnull(a.prnumber) ? true : (get(a.prnumber) == get(b.prnumber))
        return (same_prnumber && a.config == b.config && a.build == b.build &&
                a.statussha == b.statussha && a.url == b.url && a.fromkind == b.fromkind &&
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
    return BuildRef(repo, sha), sha, url, fromkind, prnumber
end

# `x` can only be Expr, Symbol, QuoteNode, T<:Number, or T<:AbstractString
function phrase_argument{T}(x::T)
    if T <: Expr || T <: Symbol || T <: QuoteNode
        return UTF8String(string(x))
    elseif T <: AbstractString || T <: Number
        return UTF8String(repr(x))
    else
        error("invalid argument type $(typeof(x))")
    end
end

function parse_phrase_match(phrase_match::AbstractString)
    fncall = match(r"`.*?`", phrase_match).match[2:end-1]
    argind = searchindex(fncall, "(")
    name = fncall[1:(argind - 1)]
    parsed_args = parse(replace(fncall[argind:end], ";", ","))
    args, kwargs = Vector{UTF8String}(), Dict{Symbol,UTF8String}()
    if isa(parsed_args, Expr) && parsed_args.head == :tuple
        started_kwargs = false
        for x in parsed_args.args
            if isa(x, Expr) && (x.head == :kw || x.head == :(=)) && isa(x.args[1], Symbol)
                @assert !(haskey(kwargs, x.args[1])) "kwargs must all be unique"
                kwargs[x.args[1]] = phrase_argument(x.args[2])
                started_kwargs = true
            else
                @assert !(started_kwargs) "kwargs must come after other args"
                push!(args, phrase_argument(x))
            end
        end
    else
        push!(args, phrase_argument(parsed_args))
    end
    return name, args, kwargs
end

function reply_status(sub::JobSubmission, state, description, url=nothing)
    params = Dict("state" => state,
                  "context" => "Nanosoldier",
                  "description" => snip(description, 140))
    url != nothing && (params["target_url"] = url)
    return GitHub.create_status(sub.config.trackrepo, sub.statussha;
                                auth = sub.config.auth, params = params)
end

function reply_comment(sub::JobSubmission, message::AbstractString)
    commentplace = isnull(sub.prnumber) ? sub.statussha : get(sub.prnumber)
    commentkind = sub.fromkind == :review ? :pr : sub.fromkind
    return GitHub.create_comment(sub.config.trackrepo, commentplace, commentkind;
                                 auth = sub.config.auth, params = Dict("body" => message))
end

function upload_report_repo!(sub::JobSubmission, markdownpath, message)
    cfg = sub.config
    sha = cd(reportdir(cfg)) do
        run(`git add -A`)
        run(`git commit -m $message`)
        headsha = chomp(readstring(`git rev-parse HEAD`))
        run(`git pull -X ours`)
        run(`git push`)
        return headsha
    end
    return "https://github.com/$(reportrepo(cfg))/blob/$(sha)/$(markdownpath)"
end
