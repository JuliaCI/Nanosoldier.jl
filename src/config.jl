
immutable Config
    nodes::Vector{Int}         # the pids for the nodes on the cluster
    cores::Vector{Int}         # the indices of the cores per node
    auth::GitHub.Authorization # the GitHub authorization used to post statuses/reports
    secret::UTF8String         # the GitHub secret used to validate webhooks
    buildrepo::UTF8String      # the main Julia repo tracked by the server
    reportrepo::UTF8String     # the repo to which result reports are posted
    workdir::UTF8String        # the server's work directory
    function Config(nodes, cores, auth, secret;
                    workdir = pwd(),
                    buildrepo = "JuliaLang/julia",
                    reportrepo = "JuliaCI/BaseBenchmarkReports",
                    makejobs = 1)
        @assert !(empty(nodes)) "need at least one node to work on"
        @assert !(empty(cores)) "need at least one core per node to work on"
        return new(nodes, cores, auth, secret, buildrepo, reportrepo, workdir)
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
