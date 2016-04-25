nodes = addprocs(["nanosoldier5"])

import Nanosoldier, GitHub

cpus = [5,6,7]
auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]
user = ENV["SERVER_USER"]

config = Nanosoldier.Config(user, nodes, cpus, auth, secret;
                            workdir = joinpath(homedir(), "workdir"),
                            trackrepo = "jrevels/julia",
                            reportrepo = "jrevels/BaseBenchmarkReports",
                            skipbuild = true)

server = Nanosoldier.Server(config)
