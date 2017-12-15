if VERSION >= v"0.7.0-DEV.2954"
    using Distributed
end

nodes = addprocs(["nanosoldier7", "nanosoldier8"], exeflags=["--compilecache=no", "--precompiled=no"])

import Nanosoldier, GitHub

cpus = [1,2,3]
auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
secret = ENV["GITHUB_SECRET"]

config = Nanosoldier.Config(ENV["USER"], nodes, cpus, auth, secret;
                            workdir = joinpath(homedir(), "workdir"),
                            trackrepo = "JuliaLang/julia",
                            reportrepo = "JuliaCI/BaseBenchmarkReports",
                            testmode = false)

server = Nanosoldier.Server(config)
