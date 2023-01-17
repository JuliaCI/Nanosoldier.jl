using Distributed
import Nanosoldier, GitHub

nodes = Dict(Any => addprocs(1))
@everywhere import Nanosoldier

auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config("nanosoldier-worker", nodes, auth, secret;
                            reportrepo = "vtjnash/NanosoldierReports",
                            admin = "vtjnash",
                            testmode = true)

server = Nanosoldier.Server(config)
