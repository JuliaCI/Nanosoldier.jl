nodes = addprocs(["nanosoldier6", "nanosoldier7"])

import Nanosoldier, GitHub

cpus = [5,6,7]
auth = GitHub.authenticate(ENV["GITHUB_AUTH"]),
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config(nodes, cpus, auth, secret;
                            workdir = joinpath(homedir(), "workdir"),
                            trackrepo = "JuliaLang/julia",
                            reportrepo = "JuliaCI/BaseBenchmarkReports",
                            skipbuild = true)

server = Nanosoldier.Server(config)
