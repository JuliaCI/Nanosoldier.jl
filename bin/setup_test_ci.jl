using Distributed
import Nanosoldier, GitHub

nodes = Dict(Any => addprocs(1))
@everywhere import Nanosoldier

auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config("nanosoldier", nodes, auth, secret;
                            workdir = joinpath(homedir(), "test_workdir"),
                            trackrepo = "vtjnash/julia",
                            reportrepo = "vtjnash/NanosoldierReports",
                            admin = "vtjnash",
                            testmode = true)

server = Nanosoldier.Server(config)
