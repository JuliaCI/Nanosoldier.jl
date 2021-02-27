using Distributed
import Nanosoldier, GitHub, Sockets

nodes = Dict(Any => addprocs(1))
@everywhere import Nanosoldier

auth = GitHub.authenticate("GITHUB_AUTH00000000000000000000000000000")
secret = GITHUB_SECRET
user = GITHUB_USER
port = 0xffff

config = Nanosoldier.Config(user, nodes, auth, secret;
                            workdir = joinpath(homedir(), "workdir"),
                            trackrepo = "JuliaLang/julia",
                            reportrepo = "JuliaCI/NanosoldierReports",
                            testmode = false)

server = Nanosoldier.Server(config)
run(server, Sockets.IPv4(0), port)
