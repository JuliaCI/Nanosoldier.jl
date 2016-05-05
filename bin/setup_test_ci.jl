nodes = addprocs(["nanosoldier6"])

import Nanosoldier, GitHub

cpus = [1,2,3]
auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config(ENV["USER"], nodes, cpus, auth, secret;
                            workdir = joinpath(homedir(), "workdir"),
                            trackrepo = "jrevels/julia",
                            reportrepo = "jrevels/BaseBenchmarkReports",
                            testmode = true, skipbuild = false)

server = Nanosoldier.Server(config)
