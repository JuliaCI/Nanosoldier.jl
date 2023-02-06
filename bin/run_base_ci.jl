using Distributed
import Nanosoldier, GitHub, Sockets

nodes = Dict(Any => addprocs(1; exeflags="--project=$(ENV["JULIA_PROJECT"])"))
@everywhere import Nanosoldier

auth = GitHub.authenticate("GITHUB_AUTH00000000000000000000000000000")
secret = GITHUB_SECRET
port = Int(0xffff)

config = Nanosoldier.Config("nanosoldier-worker", nodes, auth, secret;
                            trackrepo = "JuliaLang/julia",
                            reportrepo = "JuliaCI/NanosoldierReports",
                            testmode = false)

server = Nanosoldier.Server(config)
run(server, Sockets.IPv4(0), port)
