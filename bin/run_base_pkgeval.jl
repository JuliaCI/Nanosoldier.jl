using Distributed
import Nanosoldier, GitHub

nodes = Dict(Any => addprocs(1; exeflags="--project"))
@everywhere import Nanosoldier

auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config(ENV["USER"], nodes, auth, secret;
                            workdir = joinpath(dirname(@__DIR__), "workdir"),
                            trackrepo = "JuliaLang/julia",
                            reportrepo = "JuliaCI/NanosoldierReports",
                            trigger = r"\@nanosoldier\s*`runtests\(.*?\)`",
                            admin = "maleadt")

server = Nanosoldier.Server(config)

using Sockets
run(server, IPv4(0,0,0,0), 8888)
