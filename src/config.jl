
immutable Config
    user::UTF8String           # the OS username of the user running the server
    nodes::Vector{Int}         # the pids for the nodes on the cluster
    cpus::Vector{Int}          # the indices of the cpus per node
    auth::GitHub.Authorization # the GitHub authorization used to post statuses/reports
    secret::UTF8String         # the GitHub secret used to validate webhooks
    trackrepo::UTF8String      # the main Julia repo tracked by the server
    reportrepo::UTF8String     # the repo to which result reports are posted
    workdir::UTF8String        # the server's work directory
    testmode::Bool             # if true, jobs will run as test jobs
    function Config(user, nodes, cpus, auth, secret;
                    workdir = pwd(),
                    trackrepo = "JuliaLang/julia",
                    reportrepo = "JuliaCI/BaseBenchmarkReports",
                    testmode = false)
        @assert !(isempty(nodes)) "need at least one node to work on"
        @assert !(isempty(cpus)) "need at least one cpu per node to work on"
        return new(user, nodes, cpus, auth, secret, trackrepo,
                   reportrepo, workdir, testmode)
    end
end

# the shared space in which child nodes can work
workdir(config::Config) = config.workdir

# the report repository
reportrepo(config::Config) = config.reportrepo

# the local directory of the report repository
reportdir(config::Config) = joinpath(workdir(config), split(reportrepo(config), "/")[2])

persistdir!(path) = (!(isdir(path)) && mkdir(path); return path)

function persistdir!(config::Config)
    persistdir!(workdir(config))
    if isdir(reportdir(config))
        gitreset!(reportdir(config))
    else
        gitclone!(reportrepo(config), reportdir(config))
    end
end

function nodelog(config::Config, node, message)
    persistdir!(workdir(config))
    open(joinpath(workdir(config), "node$(node).log"), "a") do file
        println(file, now(), " | ", node, " | ", message)
    end
end
