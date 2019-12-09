using Distributed
import Nanosoldier, GitHub

nodes = Dict(Any => addprocs(["nanosoldier7", "nanosoldier8"]))
@everywhere import Nanosoldier

cpus = [1,2,3]
auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config(ENV["USER"], nodes, cpus, auth, secret;
                            workdir = joinpath(homedir(), "workdir"),
                            trackrepo = "JuliaLang/julia",
                            reportrepo = "JuliaCI/BaseBenchmarkReports",
                            testmode = false)

server = Nanosoldier.Server(config)
