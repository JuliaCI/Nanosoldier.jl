using Distributed
import Nanosoldier, GitHub

nodes = Dict(Any => addprocs(1; exeflags="--project"))
@everywhere import Nanosoldier

cpus = [i for i in 1:Sys.CPU_THREADS]
auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config(ENV["USER"], nodes, cpus, auth, secret;
                            workdir = joinpath(dirname(@__DIR__), "workdir"),
                            trackrepo = "maleadt/julia",
                            reportrepo = "maleadt/BasePkgEvalReports",
                            trigger = r"\@nanosoldier\s*`runtests\(.*?\)`",
                            admin = "maleadt")

server = Nanosoldier.Server(config)

using Sockets
run(server, IPv4(0,0,0,0), 8888)
