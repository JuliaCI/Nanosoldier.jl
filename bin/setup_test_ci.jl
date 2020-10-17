using Distributed
import Nanosoldier, GitHub

nodes = Dict(Any => addprocs(["nanosoldier6"]))
@everywhere import Nanosoldier

auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config(ENV["USER"], nodes, auth, secret;
                            workdir = joinpath(homedir(), "test_workdir"),
                            trackrepo = "christopher-dG/julia",
                            reportrepo = "christopher-dG/NanosoldierReports",
                            testmode = true)

server = Nanosoldier.Server(config)
