nodes = addprocs(["nanosoldier6", "nanosoldier7"])

import Nanosoldier, GitHub

cpus = [1,2,3]
auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]
user = ENV["SERVER_USER"]

config = Nanosoldier.Config(user, nodes, cpus, auth, secret;
                            workdir = joinpath(homedir(), "workdir"),
                            trackrepo = "JuliaLang/julia",
                            reportrepo = "JuliaCI/BaseBenchmarkReports",
                            skipbuild = true)

server = Nanosoldier.Server(config)
