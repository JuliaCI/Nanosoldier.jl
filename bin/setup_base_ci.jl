using Distributed
import Nanosoldier, GitHub

nodes = Dict(Any => addprocs(["nanosoldier7", "nanosoldier8"]))
@everywhere import Nanosoldier

auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config(ENV["USER"], nodes, auth, secret;
                            workdir = joinpath(homedir(), "workdir"),
                            trackrepo = "JuliaLang/julia",
                            reportrepo = "JuliaCI/NanosoldierReports",
                            testmode = false)

server = Nanosoldier.Server(config)
