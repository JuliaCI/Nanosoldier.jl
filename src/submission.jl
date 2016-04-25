
type JobSubmission
    config::Config
    build::BuildRef
    url::UTF8String         # the URL linking to the triggering comment
    fromkind::Symbol        # `:pr`, `:review`, or `:commit`?
    prnumber::Nullable{Int} # the job's PR number, if `fromkind` is `:pr` or `:review`
    func::UTF8String
    args::UTF8String
end

function JobSubmission(config::Config, event::GitHub.WebhookEvent, phrase::RegexMatch)
    build, url, fromkind, prnumber = parse_event(config, event)
    func, args = parse_phrase(phrase)
    return JobSubmission(config, build, url, fromkind, prnumber, func, args)
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

function parse_phrase(phrase::RegexMatch)
    try
        fncall = match(r"`.*?`", phrase.match).match[2:end-1]
        argind = searchindex(fncall, "(")
        return fncall[1:(argind - 1)], fncall[argind:end]
    catch err
        error("could not parse trigger phrase: $err")
    end
end

function create_status(sub::JobSubmission, state, description, url=nothing)
    params = Dict("state" => state,
                  "context" => "Nanosoldier",
                  "description" => snip(description, 140))
    url != nothing && (params["target_url"] = url)
    return GitHub.create_status(sub.config.buildrepo, sub.build.sha;
                                auth = sub.config.auth, params = params)
end
