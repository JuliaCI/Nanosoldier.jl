
immutable Config
    user::UTF8String           # the OS username of the user running the server
    nodes::Vector{Int}         # the pids for the nodes on the cluster
    cpus::Vector{Int}          # the indices of the cpus per node
    auth::GitHub.Authorization # the GitHub authorization used to post statuses/reports
    secret::UTF8String         # the GitHub secret used to validate webhooks
    trackrepo::UTF8String      # the main Julia repo tracked by the server
    reportrepo::UTF8String     # the repo to which result reports are posted
    workdir::UTF8String        # the server's work directory
    skipbuild::Bool            # enable for testing
    function Config(user, nodes, cpus, auth, secret;
                    workdir = pwd(),
                    trackrepo = "JuliaLang/julia",
                    reportrepo = "JuliaCI/BaseBenchmarkReports",
                    skipbuild = false)
        @assert !(isempty(nodes)) "need at least one node to work on"
        @assert !(isempty(cpus)) "need at least one cpu per node to work on"
        return new(user, nodes, cpus, auth, secret, trackrepo, reportrepo, workdir, skipbuild)
    end
end

# ensure directory exists
persistdir!(path) = (!(isdir(path)) && mkdir(path); return path)

# the shared space in which child nodes can work
workdir(config::Config) = config.workdir

# the directory where results are stored
resultdir(config::Config) = joinpath(workdir(config), "results")

# the directory where build logs are stored
logdir(config::Config) = joinpath(workdir(config), "logs")

function nodelog(config::Config, node, message)
    persistdir!(logdir(config))
    open(joinpath(logdir(config), "node$(node).log"), "a") do file
        println(file, now(), " | ", node, " | ", message)
    end
end
